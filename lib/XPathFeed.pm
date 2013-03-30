package XPathFeed;
use strict;
use warnings;
use base qw/Class::Accessor::Fast Class::Data::Inheritable/;

use XPathFeed::UserAgent;

use Cache::FileCache;
use Encode qw(decode_utf8);
use HTML::ResolveLink;
use HTML::Selector::XPath;
use HTML::Tagset;
use HTML::TreeBuilder::XPath;
use HTTP::Request;
use Scalar::Util qw(blessed);
use URI;
use XML::RSS;

our ($UserAgent, $Cache);

our $EXPIRE = 10 * 60; # 10分

our $DEFAULT_XPATH_ITEM = {
    title => '//a',
    link  => '//a/@href',
    image => '//img/@src',
};

__PACKAGE__->mk_classdata(
    params => [
        qw{
            url
            search_word
            xpath_list
            xpath_item_title
            xpath_item_link
            xpath_item_image
        },
    ],
);

__PACKAGE__->mk_accessors(
    @{__PACKAGE__->params},
    qw{
        error
        create
    },
);

sub new {
    my $class = shift;
    my %args = @_==1 ? %{$_[0]} : @_;
    return $class->SUPER::new({%args});
}

sub new_from_query {
    my ($class, $q) = @_;
    $class->new(
        map {
            $_ => $q->param($_) || '',
        } @{$class->params},
    );
}

sub ua {
    $UserAgent ||= XPathFeed::UserAgent->new;
}

sub cache {
    $Cache ||= Cache::FileCache->new(
        {
            namespace  => 'xpathfeed',
            cache_root => '/tmp/filecache',
        }
    );
}

sub resolver {
    my $self = shift;
    $self->{resolver} ||= HTML::ResolveLink->new(
        base => $self->url,
    );
}

sub uri {
    my $self = shift;
    $self->{uri} ||= URI->new($self->url)->canonical;
}

sub http_result {
    my $self = shift;
    $self->{http_result} ||= do {
        my $url    = $self->uri;
        my $cache  = $self->cache;
        my $result = $cache->get($url);
        if (!$result) {
            # キャッシュがない場合
            my $res = $self->_get($url);
            if ($res->is_success) {
                $result = $self->_res2result($res);
                $cache->set($url, $result);
            }
        } elsif (my $now = time() - $result->{cached} > $EXPIRE) {
            # キャッシュがexpireしている場合
            my $res = $self->_get($url, $now);
            if ($res->code == 304) {
                $result->{cached} = $now; # 時間だけ上書き
                $cache->set($url, $result);
            } elsif ($res->is_success) {
                $result = $self->_res2result($res);
                $cache->set($url, $result);
            }
        }
        $result || {};
    }
}

sub _get {
    my $self = shift;
    my $url  = shift;
    my $time = shift; # If-Modified-Since
    my $req = HTTP::Request->new('GET', $url);
       $req->if_modified_since($time) if $time;
    return $self->ua->request($req);
}

sub _res2result {
    my ($self, $res) = @_;
    return {
        content         => $res->content,
        resolved_content     => $self->resolver->resolve($res->content),
        decoded_content => $res->decoded_content,
        cached          => time(),
    };
}

BEGIN {
    no strict 'refs';
    for my $method (qw/content resolved_content decoded_content/) {
        *{__PACKAGE__.'::'.$method} = sub {
            my $self = shift;
            $self->{$method} = shift || $self->http_result->{$method} || '';
        }
    }
}

sub tree {
    my $self = shift;
    return $self->{tree} if exists $self->{tree};
    $self->{tree} = do {
        my $t = HTML::TreeBuilder::XPath->new;
        $t->parse($self->decoded_content);
        $t->eof;
        $t;
    } || undef;
}

sub list {
    my $self = shift;
    return $self->{list} if defined $self->{list};
    my $class = ref $self;
    my $list = eval {
        local $SIG{__WARN__} = sub { };
        my @nodes = $self->tree->findnodes(xpath($self->xpath_list));
        [map { {node => $_} } @nodes];
    } || [];
    for my $item (@$list) {
        $item or next;
        my $node = $item->{node} or next;
        my $tree = $node->clone or next; # この要素以下のtreeにする
        for my $key (sort keys %$DEFAULT_XPATH_ITEM) {
            my $method = 'xpath_item_' . $key;
            my $xpath = $self->$method() || $DEFAULT_XPATH_ITEM->{$key} or next;
            $item->{$key} = eval {
                local $SIG{__WARN__} = sub { };
                my @nodes = $tree->findnodes(xpath($xpath));
                extract($nodes[0], $key, $self->uri);
            }
        }
        push @{$self->{list}}, $item;
        $tree->delete;
    }
    $self->{list};
}

sub title {
    my $self = shift;
    $self->{title} // eval {
        local $SIG{__WARN__} = sub { };
        my ($node) = $self->tree->findnodes(xpath('title'));
        my $title = $node ? $node->as_text || '' : '';
        $title =~ s{\s+}{ }g;
        $title =~ s{(?:^\s|\s$)}{}g;
        $title;
    } || $self->url || '';
}

sub search {
    my $self = shift;
    return $self->{search_result} if defined $self->{search_result};
    my $word = $self->search_word or return;
       $word =~ s{'}{\\'}g;
    my $xpath = xpath(sprintf(q{//text()[contains(.,'%s')]/..}, $word));
    $self->{search_result} = do {
        local $SIG{__WARN__} = sub { };
        my @nodes = $self->tree->findnodes($xpath);
        [map { {node => $_} } @nodes];
    } || [];
    return $self->{search_result};
}

sub feed {
    my $self = shift;
    my $list = $self->list;
    $self->{feed} ||= do {
        my $rss = XML::RSS->new (version => '2.0');
        $rss->channel(
            title => $self->title,
            link  => $self->url,
        );
        for my $item (@$list) {
            $rss->add_item(
                title     => $item->{title},
                permaLink => $item->{link},
                enclosure => $item->{image} ? {
                    url  => $item->{image},
                    type => "image"
                } : undef,
            );
        }
        $rss->as_string;
    };
}

sub clean {
    my $self = shift;
    $self->tree or return;
    $self->tree->delete;
}

sub DESTROY {
    my $self = shift;
    $self->clean;
}

# utility method

sub xpath {
    # xpath || css selector を xpath に変換する
    # copy from Web::Scraper
    my $exp = shift;
    my $xpath = $exp =~ m!^(?:/|id\()! ? $exp : HTML::Selector::XPath::selector_to_xpath($exp);
    decode_utf8($xpath);
}

sub extract {
    my ($node, $key, $uri) = @_;
    if (blessed($node) && $node->isa('HTML::TreeBuilder::XPath::Attribute')) {
        if (is_link_element($node->getParentNode, $node->getName)) {
            URI->new_abs($node->getValue, $uri);
        } else {
            $node->getValue;
        }
    } elsif (blessed($node) && $node->can('as_text')) {
        $node->as_text;
    }
}

sub is_link_element {
    my($node, $attr) = @_;
    my $link_elements = $HTML::Tagset::linkElements{$node->tag} || [];
    for my $elem (@$link_elements) {
        return 1 if $attr eq $elem;
    }
    return;
}

1;

__END__

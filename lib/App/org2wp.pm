package App::org2wp;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';

our %SPEC;

$SPEC{'org2wp'} = {
    v => 1.1,
    summary => 'Publish Org document to WordPress as blog post',
    description => <<'_',


_
    args => {
        proxy => {
            schema => 'str*', # XXX url
            req => 1,
            description => <<'_',

Example: `https://YOURBLOGNAME.wordpress.com/xmlrpc.php`.

_
            tags => ['credential'],
        },
        username => {
            schema => 'str*',
            req => 1,
            tags => ['credential'],
        },
        password => {
            schema => 'str*',
            req => 1,
            tags => ['credential'],
        },

        filename => {
            summary => 'Path to Org document to publish',
            schema => 'filename*',
            req => 1,
            pos => 0,
            cmdline_aliases => {f=>{}},
        },

        publish => {
            schema => 'bool*',
        },
    },
};
sub org2wp {
    my %args = @_;

    my $filename = $args{filename};
    (-f $filename) or return [404, "No such file '$filename'"];

    require File::Slurper;
    my $org = File::Slurper::read_text($filename);

    require Org::To::HTML;
    my $res = Org::To::HTML::org_to_html(
        source_file => $filename,
        naked => 1,
        ignore_unknown_settings => 1,
    );
    return [500, "Can't convert Org to HTML: $res->[0] - $res->[1]"]
        if $res->[0] != 200;

    my $title;
    if ($org =~ /^#\+TITLE:\s*(.+)/m) {
        $title = $1;
    } else {
        $title = "(No title)";
    }

    my $tags;
    if ($org =~ /^#\+TAGS:\s*(.+)/m) {
        $tags = [split /\s*,\s*/, $1];
    } else {
        $tags = [];
    }

    my $cats;
    if ($org =~ /^#\+CATEGORIES:\s*(.+)/m) {
        $cats = [split /\s*,\s*/, $1];
    } else {
        $cats = [];
    }

    my $postid;
    if ($org =~ /^#\+POSTID:\s*(\d+)/m) {
        $postid = $1;
    }

    require XMLRPC::Lite;
    my $call;
    if ($postid) {
        $call = XMLRPC::Lite->proxy($args{proxy})->call(
            'wp.editPost',
            1, # blog id, set to 1
            $args{username},
            $args{password},
            $postid,
            {
                (post_status => $args{publish} ? 'publish' : 'draft') x !!(defined $args{publish}),
                post_title => $title,
                post_content => $res->[2],
                terms => [
                    #(map { +{taxonomy=>'post_tag', name=>$_} } @$tags),
                    (map { +{taxonomy=>'category', name=>$_} } @$cats),
                ],
            },
        );
    } else {
        $call = XMLRPC::Lite->proxy($args{proxy})->call(
            'wp.newPost',
            1, # blog id, set to 1
            $args{username},
            $args{password},
            {
                post_status => $args{publish} ? 'draft' : 'publish',
                post_title => $title,
                post_content => $res->[2],
                terms => [
                    #(map { +{taxonomy=>'post_tag', name=>$_} } @$tags),
                    (map { +{taxonomy=>'category', name=>$_} } @$cats),
                ],
            },
        );
    }

    my $fault = $call->fault;
    if ($fault && $fault->{faultCode}) {
        return [500, "Failed: $fault->{faultCode} - $fault->{faultString}"];
    }

    unless ($postid) {
        $postid = $call->result;
        $org =~ s/^/#+POSTID: $postid\n/;
        File::Slurper::write_text($filename, $org);
    }

    [200, "OK"];
}

1;
# ABSTRACT:

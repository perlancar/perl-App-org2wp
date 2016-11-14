package App::org2wp;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any::IfLOG '$log';

our %SPEC;

$SPEC{'org2wp'} = {
    v => 1.1,
    summary => 'Publish Org document to WordPress as blog post',
    description => <<'_',

This is originally a quick hack because I couldn't make
[org2blog](https://github.com/punchagan/org2blog) on my Emacs installation to
work. `org2wp` uses the same format as `org2blog`, but instead of an Emacs
package, `org2wp` is a CLI written in Perl.

To create a blog post, first write your Org document (e.g. in `post1.org`) using
this format:

    #+TITLE: Blog post title
    #+CATEGORY: cat1, cat2
    #+TAGS: tag1,tag2,tag3

    Text of your post ...
    ...

then:

    % org2wp post1.org

this will create a draft post. To publish directly:

    % org2wp --publish post1.org

Note that this will also modify your Org file and insert this line at the top:

    #+POSTID: 1234

where 1234 is the post ID retrieved from the server when creating the post.

After the post is created, you can update using the same command:

    % org2wp post1.org

You can use `--publish` to publish the post, or `--no-publish` to revert it to
draft.

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
    features => {
        dry_run => 1,
    },
};
sub org2wp {
    my %args = @_;

    my $dry_run = $args{-dry_run};

    my $filename = $args{filename};
    (-f $filename) or return [404, "No such file '$filename'"];

    require File::Slurper;
    my $org = File::Slurper::read_text($filename);

    require Org::To::HTML::WordPress;
    $log->infof("Converting Org to HTML ...");
    my $res = Org::To::HTML::WordPress::org_to_html_wordpress(
        source_file => $filename,
        naked => 1,
        ignore_unknown_settings => 1,
    );
    return [500, "Can't convert Org to HTML: $res->[0] - $res->[1]"]
        if $res->[0] != 200;

    my $title;
    if ($org =~ /^#\+TITLE:\s*(.+)/m) {
        $title = $1;
        $log->tracef("Extracted title from Org document: %s", $title);
    } else {
        $title = "(No title)";
    }

    my $post_tags;
    if ($org =~ /^#\+TAGS?:\s*(.+)/m) {
        $post_tags = [split /\s*,\s*/, $1];
        $log->tracef("Extracted tags from Org document: %s", $post_tags);
    } else {
        $post_tags = [];
    }

    my $post_cats;
    if ($org =~ /^#\+CATEGOR(?:Y|IES):\s*(.+)/m) {
        $post_cats = [split /\s*,\s*/, $1];
        $log->tracef("Extracted categories from Org document: %s", $post_cats);
    } else {
        $post_cats = [];
    }

    my $postid;
    if ($org =~ /^#\+POSTID:\s*(\d+)/m) {
        $postid = $1;
        $log->tracef("Org document already has post ID: %s", $postid);
    }

    require XMLRPC::Lite;
    my $call;

    # create categories if necessary
    my $cat_ids = {};
    {
        $log->infof("[api] Listing categories ...");
        $call = XMLRPC::Lite->proxy($args{proxy})->call(
            'wp.getTerms',
            1, # blog id, set to 1
            $args{username},
            $args{password},
            'category',
        );
        return [$call->fault->{faultCode}, "Can't list categories: ".$call->fault->{faultString}]
            if $call->fault && $call->fault->{faultCode};
        my $all_cats = $call->result;
        for my $cat (@$post_cats) {
            if (my ($cat_detail) = grep { $_->{name} eq $cat } @$all_cats) {
                $cat_ids->{$cat} = $cat_detail->{term_id};
                $log->tracef("Category %s already exists", $cat);
                next;
            }
            if ($dry_run) {
                $log->infof("(DRY_RUN) [api] Creating category %s ...", $cat);
                next;
            }
            $log->infof("[api] Creating category %s ...", $cat);
            $call = XMLRPC::Lite->proxy($args{proxy})->call(
                'wp.newTerm',
                1, # blog id, set to 1
                $args{username},
                $args{password},
                {taxonomy=>"category", name=>$cat},
             );
            return [$call->fault->{faultCode}, "Can't create category '$cat': ".$call->fault->{faultString}]
                if $call->fault && $call->fault->{faultCode};
            $cat_ids->{$cat} = $call->result;
        }
    }

    # create tags if necessary
    # create categories if necessary
    my $tag_ids = {};
    {
        $log->infof("[api] Listing tags ...");
        $call = XMLRPC::Lite->proxy($args{proxy})->call(
            'wp.getTerms',
            1, # blog id, set to 1
            $args{username},
            $args{password},
            'post_tag',
        );
        return [$call->fault->{faultCode}, "Can't list tags: ".$call->fault->{faultString}]
            if $call->fault && $call->fault->{faultCode};
        my $all_tags = $call->result;
        for my $tag (@$post_tags) {
            if (my ($tag_detail) = grep { $_->{name} eq $tag } @$all_tags) {
                $tag_ids->{$tag} = $tag_detail->{term_id};
                $log->tracef("Tag %s already exists", $tag);
                next;
            }
            if ($dry_run) {
                $log->infof("(DRY_RUN) [api] Creating tag %s ...", $tag);
                next;
            }
            $log->infof("[api] Creating tag %s ...", $tag);
            $call = XMLRPC::Lite->proxy($args{proxy})->call(
                'wp.newTerm',
                1, # blog id, set to 1
                $args{username},
                $args{password},
                {taxonomy=>"post_tag", name=>$tag},
             );
            return [$call->fault->{faultCode}, "Can't create tag '$tag': ".$call->fault->{faultString}]
                if $call->fault && $call->fault->{faultCode};
            $tag_ids->{$tag} = $call->result;
        }
    }

    # create or edit the post
    {
        my $meth;
        my @xmlrpc_args = (
            1, # blog id, set to 1
            $args{username},
            $args{password},
        );
        my $content;

        if ($postid) {
            $meth = 'wp.editPost';
            $content = {
                (post_status => $args{publish} ? 'publish' : 'draft') x !!(defined $args{publish}),
                post_title => $title,
                post_content => $res->[2],
                terms => {
                    category => [map {$cat_ids->{$_}} @$post_cats],
                    post_tag => [map {$tag_ids->{$_}} @$post_tags],
                },
            };
            push @xmlrpc_args, $postid, $content;
        } else {
            $meth = 'wp.newPost';
            $content = {
                post_status => $args{publish} ? 'publish' : 'draft',
                post_title => $title,
                post_content => $res->[2],
                terms => {
                    category => [map {$cat_ids->{$_}} @$post_cats],
                    post_tag => [map {$tag_ids->{$_}} @$post_tags],
                },
            };
            push @xmlrpc_args, $content;
        }
        if ($dry_run) {
            $log->infof("(DRY_RUN) [api] Create/edit post, content: %s", $content);
            return [304, "Dry-run"];
        }

        $log->infof("[api] Creating/editing post ...");
        $call = XMLRPC::Lite->proxy($args{proxy})->call($meth, @xmlrpc_args);
        return [$call->fault->{faultCode}, "Can't create/edit post: ".$call->fault->{faultString}]
            if $call->fault && $call->fault->{faultCode};
    }

    # insert #+POSTID to Org document
    unless ($postid) {
        $postid = $call->result;
        $org =~ s/^/#+POSTID: $postid\n/;
        $log->infof("[api] Inserting #+POSTID to %s ...", $filename);
        File::Slurper::write_text($filename, $org);
    }

    [200, "OK"];
}

1;
# ABSTRACT:

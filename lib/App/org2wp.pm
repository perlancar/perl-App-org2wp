package App::org2wp;

# AUTHORITY
# DATE
# DIST
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use POSIX qw(strftime);

our %SPEC;

$SPEC{'org2wp'} = {
    v => 1.1,
    summary => 'Publish Org document (or heading) to WordPress as blog post',
    description => <<'_',

This is originally a quick hack because I couldn't make
[org2blog](https://github.com/punchagan/org2blog) on my Emacs installation to
work after some update. `org2wp` uses the same format as `org2blog`, but instead
of being an Emacs package, it is a CLI script written in Perl.

First, create `~/org2wp.conf` containing the API credentials, e.g.:

    proxy=https://YOURBLOGNAME.wordpress.com/xmlrpc.php
    username=YOURUSERNAME
    password=YOURPASSWORD

You can also put multiple credentials in the configuration file using profile
sections, e.g.:

    [profile=blog1]
    proxy=https://YOURBLOG1NAME.wordpress.com/xmlrpc.php
    username=YOURUSERNAME
    password=YOURPASSWORD

    [profile=blog2]
    proxy=https://YOURBLOG2NAME.wordpress.com/xmlrpc.php
    username=YOURUSERNAME
    password=YOURPASSWORD

and specify which profile you want using command-line option e.g.
`--config-profile blog1`.

### Document mode

You can use the whole Org document file as a blog post (document mode) or a
single heading as a blog post (heading mode). The default is document mode. To
create a blog post, write your Org document (e.g. in `post1.org`) using this
format:

    #+TITLE: Blog post title
    #+CATEGORY: cat1, cat2
    #+TAGS: tag1,tag2,tag3

    Text of your post ...
    ...

then:

    % org2wp post1.org

this will create a draft post. To publish directly:

    % org2wp --publish post1.org

Note that this will also modify your Org file and insert this setting line at
the top:

    #+POSTID: 1234
    #+POSTTIME: [2020-09-16 Wed 11:51]

where 1234 is the post ID retrieved from the server when creating the post, and
post time will be set to the current local time.

After the post is created, you can update using the same command:

    % org2wp post1.org

You can use `--publish` to publish the post, or `--no-publish` to revert it to
draft.

To set more attributes:

    % org2wp post1.org --comment-status open \
        --extra-attr ping_status=closed --extra-attr sticky=1

Another example, to schedule a post in the future:

    % org2wp post1.org --schedule 20301225T00:00:00

### Heading mode

In heading mode, each heading will become a separate blog post. To enable this
mode, specify `--post-heading-level` (`-l`) to 1 (or 2, or 3, ...). This will
cause a level-1 (or 2, or 3, ...) heading to be assumed as an individual blog
post. For example, suppose you have `blog.org` with this content:

    * Post A                  :tag1:tag2:tag3:
    :PROPERTIES:
    :CATEGORY: cat1, cat2, cat3
    :END:

    Some text...

    ** a heading of post 1
    more text ...
    ** another heading of post 1
    even more text ...

    * Post B                  :tag2:tag4:
    Some text ...

with this command:

    % org2wp blog.org -l 1

there will be two blog posts to be posted because there are two level-1
headings: `Post A` and `Post B`. Post A contains level-2 headings which will
become headings of the blog post. Headline tags will become blog post tags, and
to specify categories you use the property `CATEGORY` in the `PROPERTIES`
drawer.

If, for example, you specify `-l 2` instead of `-l 1` then the level-2 headings
will become blog posts.


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

        post_heading_level => {
            summary => 'Specify which heading level to be regarded as an individula blog post',
            schema => 'posint*',
            cmdline_aliases => {l=>{}},
            description => <<'_',

If specified, this will enable *heading mode* instead of the default *document
mode*. In the document mode, the whole Org document file is regarded as a single
blog post. In the *heading mode*, a heading of certain level will be regarded as
a single blog post.

_
        },

        publish => {
            summary => 'Whether to publish post or make it a draft',
            schema => 'bool*',
            description => <<'_',

Equivalent to `--extra-attr post_status=published`, while `--no-publish` is
equivalent to `--extra-attr post_status=draft`.

_
        },
        schedule => {
            summary => 'Schedule post to be published sometime in the future',
            schema => 'date*',
            description => <<'_',

Equivalent to `--publish --extra-attr post_date=DATE`. Note that WordPress
accepts date in the `YYYYMMDD"T"HH:MM:SS` format, but you specify this option in
regular ISO8601 format. Also note that time is in your chosen local timezone
setting.

_
        },
        comment_status => {
            summary => 'Whether to allow comments (open) or not (closed)',
            schema => ['str*', in=>['open','closed']],
            default => 'closed',
        },
        extra_attrs => {
            'x.name.is_plural' => 1,
            'x.name.singular' => 'extra_attr',
            summary => 'Set extra post attributes, e.g. ping_status, post_format, etc',
            schema => ['hash*', of=>'str*'],
        },
    },
    args_rels => {
        choose_one => [qw/publish schedule/],
    },
    features => {
        dry_run => 1,
    },
    links => [
        {url=>'prog:pod2wp'},
        {url=>'prog:html2wp'},
        {url=>'prog:wp-xmlrpc'},
    ],
};
sub org2wp {
    my %args = @_;

    my $dry_run = $args{-dry_run};

    my $filename = $args{filename};
    (-f $filename) or return [404, "No such file '$filename'"];

    require File::Slurper;
    my $org_source = File::Slurper::read_text($filename);

    my $post_heading_level = $args{post_heading_level};
    my $mode = 'document';
    if (defined $post_heading_level) {
        $mode = 'heading';
    }

    # 1. collect the posts information: the org source, along with their titles,
    # existing post ID's (if available), as well as all categories and tags we
    # want to use.
    my @posts_srcs;   # ("org1", "org2", ...)
    my @posts_titles; # ("title1", "title2", ...)
    my @posts_ids;    # (101,     undef,   ...)
    my @posts_tags;   # ([tag1_for_post1,tag2_for_post1], [tag1_for_post2,...], ...)
    my @posts_cats;   # ([cat1_for_post1,cat2_for_post1], [cat1_for_post2,...], ...)

    require Org::To::HTML::WordPress;
    if ($mode eq 'heading') {
        require Org::Parser;
        my $org_parser = Org::Parser->new;
        my $org_doc   = $org_parser->parse($org_source);

        my @headlines = $org_doc->find(
            sub {
                my $el = shift;
                $el->isa("Org::Element::Headline") && $el->level == $post_heading_level;
            });
        for my $headline (@headlines) {
            log_trace "Found blog post in heading: %s", $headline->as_string;
            push @posts_srcs, $headline->as_string . $headline->children_as_string;
            # XXX posts_ids
            # XXX posts_ids
            # XXX post_tags
            # XXX post_cats
        }
    } else {
        push @posts_srcs, $org_source;

        my $title;
        if ($org_source =~ /^#\+TITLE:\s*(.+)/m) {
            $title = $1;
            log_trace("Extracted title from Org document: %s", $title);
        } else {
            $title = "(No title)";
        }
        push @posts_titles, $title;

        my $post_tags;
        if ($org =~ /^#\+TAGS?:\s*(.+)/m) {
            $post_tags = [split /\s*,\s*/, $1];
            log_trace("Extracted tags from Org document: %s", $post_tags);
        } else {
            $post_tags = [];
        }
        push @posts_tags, $post_tags;

        my $post_cats;
        if ($org =~ /^#\+CATEGOR(?:Y|IES):\s*(.+)/m) {
            $post_cats = [split /\s*,\s*/, $1];
            log_trace("Extracted categories from Org document: %s", $post_cats);
        } else {
            $post_cats = [];
        }
        push @posts_cats, $post_cats;

        my $post_id;
        if ($org =~ /^#\+POSTID:\s*(\d+)/m) {
            $post_id = $1;
            log_trace("Org document already has post ID: %s", $post_id);
        }
        push @posts_ids, $post_id;
    }

    # 2. convert hte org sources to htmls

    log_info("Converting Org to HTML ...");
    my $res = Org::To::HTML::WordPress::org_to_html_wordpress(
        source_file => $filename,
        naked => 1,
        ignore_unknown_settings => 1,
    );
    return [500, "Can't convert Org to HTML: $res->[0] - $res->[1]"]
        if $res->[0] != 200;

    require XMLRPC::Lite;
    my $call;

    # 3. create categories if necessary

    my $cat_ids = {};
    {
        log_info("[api] Listing categories ...");
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
                log_trace("Category %s already exists", $cat);
                next;
            }
            if ($dry_run) {
                log_info("(DRY_RUN) [api] Creating category %s ...", $cat);
                next;
            }
            log_info("[api] Creating category %s ...", $cat);
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

    # 4. create tags if necessary

    my $tag_ids = {};
    {
        log_info("[api] Listing tags ...");
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
                log_trace("Tag %s already exists", $tag);
                next;
            }
            if ($dry_run) {
                log_info("(DRY_RUN) [api] Creating tag %s ...", $tag);
                next;
            }
            log_info("[api] Creating tag %s ...", $tag);
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

    # 5. create or edit the posts

    {
        my $meth;
        my @xmlrpc_args = (
            1, # blog id, set to 1
            $args{username},
            $args{password},
        );
        my $content;

        my $publish = $args{publish};
        my $schedule = defined($args{schedule}) ?
            strftime("%Y%m%dT%H:%M:%S", localtime($args{schedule})) : undef;
        $publish = 1 if $schedule;

        if ($postid) {
            $meth = 'wp.editPost';
            $content = {
                (post_status => $publish ? 'publish' : 'draft') x !!(defined $publish),
                (post_date => $schedule) x !!(defined $schedule),
                post_title => $title,
                post_content => $res->[2],
                terms => {
                    category => [map {$cat_ids->{$_}} @$post_cats],
                    post_tag => [map {$tag_ids->{$_}} @$post_tags],
                },
                comment_status => $args{comment_status},
                %{ $args{extra_attrs} // {} },
            };
            push @xmlrpc_args, $postid, $content;
        } else {
            $meth = 'wp.newPost';
            $content = {
                post_status => $publish ? 'publish' : 'draft',
                (post_date => $schedule) x !!(defined $schedule),
                post_title => $title,
                post_content => $res->[2],
                terms => {
                    category => [map {$cat_ids->{$_}} @$post_cats],
                    post_tag => [map {$tag_ids->{$_}} @$post_tags],
                },
                comment_status => $args{comment_status},
                %{ $args{extra_attrs} // {} },
            };
            push @xmlrpc_args, $content;
        }
        if ($dry_run) {
            log_info("(DRY_RUN) [api] Create/edit post, content: %s", $content);
            return [304, "Dry-run"];
        }

        log_info("[api] Creating/editing post ...");
        log_trace("[api] xmlrpc method=%s, args=%s", $meth, \@xmlrpc_args);
        $call = XMLRPC::Lite->proxy($args{proxy})->call($meth, @xmlrpc_args);
        return [$call->fault->{faultCode}, "Can't create/edit post: ".$call->fault->{faultString}]
            if $call->fault && $call->fault->{faultCode};
    }

    # 6. insert #+POSTID/:POSTID: and #+POSTTIME/:POSTTIME: to Org
    # document/heading

    unless ($postid) {
        $postid = $call->result;
        $org =~ s/^/#+POSTID: $postid\n/;
        log_info("[api] Inserting #+POSTID to %s ...", $filename);
        File::Slurper::write_text($filename, $org);
    }

    [200, "OK"];
}

1;
# ABSTRACT:

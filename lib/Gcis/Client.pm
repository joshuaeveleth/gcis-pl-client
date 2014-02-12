package Gcis::Client;
use Mojo::UserAgent;
use Mojo::Base -base;
use Mojo::Log;
use JSON::XS;
use YAML::XS qw/LoadFile/;
use Path::Class qw/file/;
use Data::Dumper;
use v5.14;

our $VERSION = 0.01;

has url      => 'http://localhost:3000';
has 'key';
has 'error';
has ua       => sub { state $ua   ||= Mojo::UserAgent->new(); };
has logger   => sub { state $log  ||= Mojo::Log->new(); };
has json     => sub { state $json ||= JSON::XS->new(); };
has accept   => "application/json";

sub auth_hdr { ($a = shift->key) ? ("Authorization" => "Basic $a") : () }

sub hdrs {
  my $c = shift;
  +{$c->auth_hdr, "Accept" => $c->accept};
}

sub _follow_redirects {
    my $s = shift;
    my $tx = shift;
    while ($tx && $tx->res && $tx->res->code && ($tx->res->code == 302 || $tx->res->code==303 )) {
        my $next = $tx->res->headers->location;
        $tx = $s->ua->get($next => $s->hdrs);
    }
    return $tx;
}

sub get {
    my $s = shift;
    my $path = shift;
    my $tx = $s->ua->get($s->url."$path" => $s->hdrs);
    $tx = $s->_follow_redirects($tx);
    my $res = $tx->success;
    unless ($res) {
        if ($tx->res->code && $tx->res->code == 404) {
            # $s->logger->debug("not found : $path");
            $s->error("not found : $path");
            return;
        }
        $s->error($tx->error);
        $s->logger->error($tx->error);
        return;
    };
    my $json = $res->json or do {
        $s->logger->debug("no json from $path : ".$res->to_string);
        $s->error("No JSON returned from $path : ".$res->to_string);
        return;
    };
    return wantarray && ref($json) eq 'ARRAY' ? @$json : $json;
}

sub post {
    my $s = shift;
    my $path = shift;
    my $data = shift;
    my $tx = $s->ua->post($s->url."$path" => $s->hdrs => json => $data );
    $tx = $s->_follow_redirects($tx);
    my $res = $tx->success or do {
        $s->logger->error("$path : ".$tx->error.$tx->res->body);
        return;
    };
    return unless $res;
    my $json = $res->json or return $res->body;
    return $res->json;
}

sub delete {
    my $s = shift;
    my $path = shift;
    my $tx = $s->ua->delete($s->url."$path" => $s->hdrs);
    my $res = $tx->success;
    unless ($res) {
        if ($tx->res->code && $tx->res->code == 404) {
            $s->error("not found : $path");
            return;
        }
        $s->error($tx->error);
        $s->logger->error($tx->error);
        return;
    };
    return $res->body;
}

sub put_file {
    my $s = shift;
    my $path = shift;
    my $file = shift;
    my $data = file($file)->slurp;
    my $tx = $s->ua->put($s->url."$path" => $s->hdrs => $data );
    $tx = $s->_follow_redirects($tx);
    my $res = $tx->success or do {
        $s->logger->error("$path : ".$tx->error.$tx->res->body);
        return;
    };
    return unless $res;
    my $json = $res->json or return $res->body;
    return $res->json;
}


sub post_quiet {
    my $s = shift;
    my $path = shift;
    my $data = shift;
    my $tx = $s->ua->post($s->url."$path" => $s->hdrs => json => $data );
    $tx = $s->_follow_redirects($tx);
    my $res = $tx->success or do {
        $s->logger->error("$path : ".$tx->error.$tx->res->body) unless $tx->res->code == 404;
        return;
    };
    return unless $res;
    my $json = $res->json or return $res->body;
    return $res->json;
}

sub find_credentials {
    my $s = shift;
    my $home = $ENV{HOME};
    die "need url to find credentials" unless $s->url;
    my $conf_file = "$home/etc/Gcis.conf";
    -e $conf_file or die "Missing $conf_file";
    my $conf = LoadFile($conf_file);
    my @found = grep { $_->{url} eq $s->url } @$conf;
    die "Multiple matches for ".$s->url." in $conf_file." if @found > 1;
    die "No matches for ".$s->url." in $conf_file." if @found < 1;
    my $key = $found[0]->{key} or die "no key for ".$s->url." in $conf_file";
    $s->key($key);
    return $s;
}

sub login {
    my $c = shift;
    my $got = $c->get('/login') or return;
    $c->get('/login')->{login} eq 'ok' or return;
    return $c;
}

sub get_chapter_map {
    my $c = shift;
    my $report = shift or die "no report";
    my $all = $c->get("/report/$report/chapter?all=1") or die $c->url.' : '.$c->error;
    my %map = map { $_->{number} // $_->{identifier} => $_->{identifier} } @$all;
    return wantarray ? %map : \%map;
}

sub figures {
    my $c = shift;
    my %a = @_;
    my $report = $a{report} or die "no report";
    if (my $chapter_number = $a{chapter_number}) {
        $c->{_chapter_map}->{$report} //= $c->get_chapter_map($report);
        $a{chapter} = $c->{_chapter_map}->{$report}->{$chapter_number};
    }
    my $figures;
    if (my $chapter = $a{chapter}) {
        $figures = $c->get("/report/$report/chapter/$chapter/figure?all=1") or die $c->error;
    } else {
        $figures = $c->get("/report/$report/figure?all=1") or die $c->error;
    }
    return wantarray ? @$figures : $figures;
}

sub get_form {
    my $c = shift;
    my $obj = shift;
    my $uri = $obj->{uri} or die "no uri in ".Dumper($obj);
    # The last backslash becomes /form/update
    $uri =~ s[/([^/]+)$][/form/update/$1];
    return $c->get($uri);
}

sub connect {
    my $class = shift;
    my %args = @_;

    my $url = $args{url} or die "missing url";
    my $c = $class->new;
    $c->url($url);
    $c->find_credentials->login or die "Failed to log in to $url";
    return $c;
}

1;

__END__

=head1 NAME

Gcis::Client -- Perl client for interacting with the GCIS API

=head1 SYNOPSIS

    my $c = Gcis::Client->new;

    $c->url("http://data.globalchange.gov");

    $c->logger(Mojo::Log->new(path => '/tmp/gcis-client.log');

    my $chapters = $c->get("/report/nca3draft/chapter?all=1") or die $c->error;

    my $c = Gcis::Client->new(url => 'http://data.globalchange.gov');

    my $c = Gcis::Client->new
        ->url('http://data.globalchange.gov')
        ->logger($logger)
        ->find_credentials
        ->login;

    my $ref = $c->post(
      "/reference",
      {
        identifier        => $uuid,
        publication_uri  => "/report/$parent_report",
        sub_publication_uris => $chapter_uris,
        attrs             => $rec,
      }
    ) or die $c->error;

=head1 DESCRIPTION

This is a simple client for the GCIS API, based on L<Mojo::UserAgent>.

=head1 METHODS

=head2 connect

    my $c = Gcis::Client->connect(url => $url);

Shorthand for Gcis::Client->new->url($url)->find_credentials->login or die "Failed to log in to $url";

=head2 find_credentials

Matches a URL with one in the configuration file.  See CONFIGURATION below.

=head2 login

Verify that a get request to /login succeeds.

Returns the client object if and only if it succeeds.

    $c->login;

=head2 get_chapter_map

Get a map from chapter number to identifer.

    my $identifier = $c->get_chapter_map('nca3')->{1}

=head2 get

    Get a URL, requesting JSON, converting an arrayref to an array
if called in an array context.

=head1 CONFIGRATION

Credentials can be stored in a YAML file called ~/etc/Gcis.conf.
This contains URLs and keys, in this format :

    - url      : http://data-stage.globalchange.gov
      userinfo : me@example.com:298015f752d99e789056ef826a7db7afc38a8bbd6e3e23b3
      key      : M2FiLTg2N2QtYjhiZTVhM5ZWEtYjNkM5ZWEtYjNkMS00LTgS00LTg2N2QtYZDFhzQyNGUxCg==

    - url      : http://data.globalchange.gov
      userinfo : username:pass
      key      : key

=head1 SEE ALSO

L<Mojo::UserAgent>, L<Mojo::Log>

=cut
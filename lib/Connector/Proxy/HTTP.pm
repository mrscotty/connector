# Proxy class to get/set data using HTTP POST
#
package Connector::Proxy::HTTP;

use strict;
use warnings;
use English;
use Try::Tiny;
use Data::Dumper;
use LWP::UserAgent;
use Template;

use Moose;
extends 'Connector::Proxy';

has timeout => (
    is => 'rw',
    isa => 'Int',
    required => 0,
    default => 10,
    );

has proxy => (
    is => 'rw',
    isa => 'Str',
    required => 0,
    );

has agent => (
    is => 'rw',
    isa => 'Object',
    lazy => 1,
    builder => '_init_agent',
);


# If not set, the path items are added to the base url as uri path
# if set, the keys from named parameters are combined and used as query string
# not implemented
#has named_parameters => (
#    is => 'rw',
#    isa => 'ArrayRef|Str|Undef',
#    trigger => \&_convert_parameters,
#    );

has use_net_ssl => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
    );

has ssl_ignore_hostname => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
    );

has ssl_ignore_mode => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
    );

has certificate_file => (
    is => 'rw',
    isa => 'Str',
    );

has certificate_key_file => (
    is => 'rw',
    isa => 'Str',
    );

has certificate_p12_file => (
    is => 'rw',
    isa => 'Str',
    );

has certificate_key_password => (
    is => 'rw',
    isa => 'Str',
    );

has ca_certificate_path => (
    is => 'rw',
    isa => 'Str',
    );

has ca_certificate_file => (
    is => 'rw',
    isa => 'Str',
    );

has file => (
    is => 'rw',
    isa => 'Str',
    );

has content => (
    is  => 'rw',
    isa => 'Str',
    );

has header => (
    is  => 'ro',
    isa => 'HashRef',
    );

has content_type => (
    is  => 'rw',
    isa => 'Str',
    );

has http_method => (
    is => 'rw',
    isa => 'Str',
    default => 'PUT',
    );

has http_auth => (
    is  => 'ro',
    isa => 'HashRef',
    );

# If named_parameters is set using a string (necessary atm for Config::Std)
# its converted to an arrayref. Might be removed if Config::* improves
# This might create indefinite loops if something goes wrong on the conversion!
sub _convert_parameters {
    my ( $self, $new, $old ) = @_;

    # Test if the given value is a non empty scalar
    if ($new && !ref $new && (!$old || $new ne $old)) {
        my @attrs = split(" ", $new);
        $self->named_parameters( \@attrs )
    }

}

sub _init_agent {

    my $self = shift;

    my %ENV_BACKUP = %ENV;

    my $ua = LWP::UserAgent->new;
    $ua->timeout( $self->timeout() );
    if ($self->proxy()) {
        $ua->proxy(['http', 'https'], $self->proxy());
    }

    # Force usage of net::ssl
    if ($self->use_net_ssl()) {
        require Net::SSL;
        $ENV{PERL_NET_HTTPS_SSL_SOCKET_CLASS} = "Net::SSL";

        if ($self->certificate_p12_file) {
            $ENV{HTTPS_PKCS12_FILE}  = $self->certificate_p12_file;

            if ($self->certificate_key_file || $self->certificate_file) {
                die "Options certificate_file/certificate_key_file and certificate_p12_file are mutually exclusive";
            }

            if ($self->certificate_key_password) {
                $ENV{HTTPS_PKCS12_PASSWORD}  = $self->certificate_key_password;
            }
        }

        if ($self->certificate_key_file) {
            if ($self->certificate_key_password) {
                die "Net::SSL does not support password protected keys - use certificate_p12_file instead";
            }

            if (!$self->certificate_file) {
                die "You need to pass certificate AND key file, use certificate_p12_file to pass a PKCS12";
            }

            $ENV{HTTPS_KEY_FILE}  = $self->certificate_key_file;
            $ENV{HTTPS_CERT_FILE} = $self->certificate_file;

        } elsif ($self->certificate_file) {
            die "You need to pass certificate AND key file, use certificate_p12_file to pass a PKCS12";
        }

        if ($self->ca_certificate_path) {
            $ENV{HTTPS_CA_DIR} = $self->ca_certificate_path;
        }

        if ($self->ca_certificate_file) {
            $ENV{HTTPS_CA_FILE} = $self->ca_certificate_file;
        }

        $self->log()->trace('Using Net::SSL, EVN is' . Dumper $ENV);

    } # end of Net:SSL, IO::Socket::SSL
    elsif( $self->LOCATION() =~ /^https:/i ) {

        use IO::Socket::SSL;
        $ENV{PERL_NET_HTTPS_SSL_SOCKET_CLASS} = "IO::Socket::SSL";

        my $ssl_opts = {
            verify_hostname => ($self->ssl_ignore_hostname ? 0 : 1),
            SSL_verify_mode => ($self->ssl_ignore_mode ? 0 : 1)
        };
        if ($self->certificate_p12_file) {
            die "Using pkcs12 containers is not supported by IO::Socket::SSL"
        }

        if ($self->certificate_key_file) {
            if (!$self->certificate_file) {
                die "You need to pass certificate AND key file";
            }
            $ssl_opts->{SSL_key_file}  = $self->certificate_key_file;
            $ssl_opts->{SSL_cert_file}  = $self->certificate_file;

            if ( $self->certificate_key_password ) {
                $ssl_opts->{SSL_passwd_cb} = sub { return $self->certificate_key_password; };
            }

        } elsif ($self->certificate_file) {
            die "You need to pass certificate AND key file";
        }

        if ($self->ca_certificate_path) {
	        $ssl_opts->{SSL_ca_path}  = $self->ca_certificate_path;
        }

        if ($self->ca_certificate_file) {
            $ssl_opts->{SSL_ca_file}  = $self->ca_certificate_file;
        }

        $ua->ssl_opts( %{$ssl_opts} );

        $self->log()->trace('Using IO::Socket::SSL with options ' . Dumper $ssl_opts);
    } else {
        # No ssl
    }

    return $ua;
}


sub get {
    my $self = shift;

    my @args = $self->_build_path( shift );

    my $url = $self->LOCATION();
    if (@args) {
        $url .= '/'.join('/', @args);
    }
    $self->log()->debug('Make LWP call to ' . $url );

    my $req = HTTP::Request->new('GET' => $url);

    # use basic auth if supplied
    my $auth=$self->http_auth();
    if ($auth){
        $req->authorization_basic($auth->{user},$auth->{pass});
    }

    # extra headers
    my $header = $self->header();
    foreach my $key (%{$header}) {
        $req->header($key, $header->{$key} );
    }

    my $response = $self->agent()->request($req);
    
    if (!$response->is_success) {
        $self->log()->error($response->status_line);
        die "Unable to retrieve data from server";
    }

     return $self->_parse_result($response);
}

sub set {

    my $self = shift;
    my $file = shift;
    my $data = shift;
    # build url
    my $url = $self->_sanitize_path( $file, $data );
    # create content from template
    my $content;
    if ($self->content()) {
        $self->log()->debug('Process template for content ' . $self->content());
        my $template = Template->new({});

        $data = { DATA => $data } if (ref $data eq '');

        $template->process( \$self->content(), $data, \$content) || die "Error processing content template.";
    } else {
        if (ref $data ne '') {
            die "You need to define a content template if data is not a scalar";
        }
        $content = $data;
    }

    # create request
    my $req = HTTP::Request->new($self->http_method() => $url);
    # use basic auth if supplied
    my $auth=$self->http_auth();
    if ($auth){
        $req->authorization_basic($auth->{user},$auth->{pass});
    }
    # set content_type if supplied
    if ($self->content_type()){
        $req->content_type($self->content_type());
    }

    # extra headers
    my $header = $self->header();
    foreach my $key (%{$header}) {
        $req->header($key, $header->{$key} );
    }

    # set generated content
    $req->content($content);

    my $response = $self->agent()->request($req);
    # error handling
    if (!$response->is_success) {
        $self->log()->error($response->status_line);
        $self->log()->error($response->decoded_content);
        die "Unable to upload data to server";
    }

    $self->log()->debug("Set responded with: " . $response->status_line);
    $self->log()->trace($response->decoded_content) if ($self->log()->is_trace());

    return 1;
}

sub _sanitize_path {

    my $self = shift;
    my $inargs = shift;
    my $data = shift;

    my @args = $self->_build_path_with_prefix( $inargs );

    my $file;
    my $filename = $self->{LOCATION};
    if ($self->file()) {
        my $pattern = $self->file();
        my $template = Template->new({});
        $self->log()->debug('Process template ' . $pattern);
        $template->process( \$pattern, { ARGS => \@args, DATA => $data }, \$file) || die "Error processing argument template.";
    } elsif (scalar @args) {
        $file = join $self->DELIMITER(), @args;
    }

    if (defined $file && $file ne "") {
        $file =~ s/[^\s\w\.-]//g;
        $filename .= '/'.$file;
    }

    $self->log()->debug('Filename evaluated to ' . $filename);

    return $filename;
}

sub _parse_result {

    my $self  = shift;
    my $response = shift;
    return $response->decoded_content;
}


no Moose;
__PACKAGE__->meta->make_immutable;

1;
__END__

=head 1 NAME

Connector::Proxy::HTTP

=head 1 DESCRIPTION

Send or retrieve data from a defined URI using HTTP.

=head1 USAGE

=head2 minimal setup

  Connector::Proxy::HTTP::Lite->new({
    LOCATION => 'https://127.0.0.1/my/base/url',
  });

=head2 additional options

=over

=item named_parameters

not implemented yet

=item header

A HashRef, the key/value pairs are set as HTTP headers.

=item http_auth

A HashRef with I<user> and I<pass> used as credentials to perform a
HTTP Basic Authentication.

=back

=head2 LWP options

=over

=item timeout

Timeout for the connection in seconds, default is 10.

=item proxy

URL of a proxy to use, must include protocol and port,
e.g. https://proxy.intranet.company.com:8080/

=head2 Parameter used with set

=over

=item file

A template toolkit string to generate the filename to write to. The
arguments given as connector location are available in I<ARGS>, the
payload data in I<DATA>. The result is sanitized and must not contain
any other characters than word, whitespace, dash or dot.

The result is appended to LOCATION.

=item content

A template toolkit string to generate the payload, receives the payload
argument as HasRef in I<DATA>.

=item content_type

The Content-Type header to use, default is no header.

=item http_method

The http method to use, default is PUT.

=back

=head2 SSL support

This connector supports client authentication using certificates.

=over

=item use_net_ssl

Set this to a true value to use Net::SSL as backend library (otherwise
IO::Socket::SSL is used). Be aware the Net::SSL does not check the hostname
of the server certificate so Man-in-the-Middle-Attacks might be possible.
You should use this only with a really good reason or if you need support
for PKCS12 containers.

=item ssl_ignore_hostname

Do not validate the hostname of the server certificate (only useful with
IO::Socket::SSL as Net::SSL does not check the hostname at all).

=item certificate_file

Path to a PEM encoded certificate file.

=item certificate_key_file

Path to a PEM encoded key file.

=item certificate_p12_file

Path to a PKCS12 container file. This is only supported by Net:SSL and can
not be used together with certificate_file/certificate_key_file.

=item certificate_key_password

The plain password of your encrypted key or PKCS12 container. Note that
Net::SSL does not support password protected keys. You need to use a PKCS12
container instead! Leave this empty if your key is not protected by a password.

=item ca_certificate_path

Path to a directory with trusted certificates (with openssl hashed names).
Also used to validate the server certificate even if no client authentication
is used.

=item ca_certificate_file

Same as ca_certificate_path pointing to a single file.

=item ssl_ignore_mode

Boolean, turn of validation of ssl peer certificate (IO::Socket only).

=back

=head1 Result Handling

If you need to parse the result returned by get, inherit from the class
an implement I<_parse_result>. This method receives the response object
from the user agent call and must return a scalar value which is returned
to the caller.
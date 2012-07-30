#file:Plugin/Plugin_CAS.pm
#-------------------------
#!/usr/bin/perl
package Plugin::Plugin_CAS;

use strict;
use warnings;

BEGIN {
    use Exporter ();
    our @ISA       = qw(Exporter);
    our @EXPORT_OK = qw(&plugin);
}

use Apache2::Log;
use Apache2::Reload;
use Apache2::Request;
use APR::URI;

use Core::VultureUtils
  qw(&session &get_memcached &set_memcached &get_cookie &get_app &get_DB_object);

use Apache2::Const -compile => qw(OK FORBIDDEN);

sub plugin {
    my ( $package_name, $r, $log, $dbh, $intf, $app, $options ) = @_;

    $log->debug("########## Plugin_CAS ##########");
    my $mc_conf = $r->pnotes('mc_conf');
    my ( $action, $service, $ticket );
    my $req = Apache2::Request->new($r);

    #Get parameters
    $action = @$options[0];

    my $url = $req->param('url');
    $service = $req->param('service') || $req->param('serviceValidate');
    $ticket = $req->param('ticket');

    #Get memcached data
    my (%users);
    %users =
      %{ Core::VultureUtils::get_memcached( 'vulture_users_in', $mc_conf )
          || {} };

    #CAS Portal doesn't have auth
    my $auths = $intf->{'auth'};
    if ( not defined @$auths or not @$auths ) {
        $log->debug("Auth in CAS is undefined");
        return Apache2::Const::FORBIDDEN;
    }

    #If user want to login in CAS (redirected by service), set $url_to_redirect
    if ( $action eq 'login' ) {
        $log->debug("Login");

        #User not logged in SSO
        my $parsed_service = APR::URI->parse( $r->pool, $service );
        my $host = $parsed_service->hostname;

        #Get app
        my $app = Core::VultureUtils::get_app( $log, $host, $dbh, $intf->{id} )
          if defined $host;

        $app->{'auth'} = $auths;

        #Send app if exists.
        $r->pnotes( 'app' => $app );

        #Getting SSO session if exists.
        my $SSO_cookie_name =
          Core::VultureUtils::get_cookie( $r->headers_in->{Cookie},
            $r->dir_config('VultureProxyCookieName') . '=([^;]*)' );
        my (%session_SSO);

        Core::VultureUtils::session( \%session_SSO, $intf->{sso_timeout},
            $SSO_cookie_name, $log, $mc_conf, $intf->{sso_update_access_time} );

        #Get session id if not exists
        if ( $SSO_cookie_name ne $session_SSO{_session_id} ) {
            $log->debug("Replacing SSO id");
            $SSO_cookie_name = $session_SSO{_session_id};
        }
        my $path = "/";
        if ( $app->{name} =~ /(.*)\/(.*)/ ) {
            $path = $path . $2;
        }

        #Set cookie for SSO portal
        $r->err_headers_out->add(
                'Set-Cookie' => $r->dir_config('VultureProxyCookieName') . "="
              . $session_SSO{_session_id}
              . "; path="
              . $path
              . "; domain="
              . $r->hostname );

        $r->pnotes( 'id_session_SSO' => $SSO_cookie_name );

        #Destroy useless handlers
        $r->set_handlers( PerlFixupHandler => undef );

        return Apache2::Const::OK;

        #Validate service ticket
    }
    elsif ( $action eq 'validate' ) {
        $log->debug("Validate ticket");
        my $res = "no\n\n";

#Each user has an hash like { ticket => id_ticket, ticket_service => service, ticket_created => timestamp, SSO => id_session_SSO }

        while ( my ( $key, $hashref ) = each %users ) {
            my %user_hash = %$hashref;

            #Delete old ticket if too old
            if (
                $intf->{cas_st_timeout} > 0
                and (
                    time() - $user_hash{ticket_created} >
                    $intf->{cas_st_timeout} )
              )
            {
                delete $hashref->{ticket};
                delete $hashref->{ticket_service};
                delete $hashref->{ticket_created};
                next;
            }

            #Check if parameter matches with stored tickets
            if (    exists $user_hash{ticket}
                and $user_hash{ticket} eq $ticket
                and exists $user_hash{ticket_service}
                and $user_hash{ticket_service} eq $service
                and exists $user_hash{ticket_created} )
            {
                $res = "yes\n$key\n";

                #Unvalidate ticket
                delete $hashref->{ticket};
                delete $hashref->{ticket_service};
                delete $hashref->{ticket_created};

                #Stop loop
                last;
            }
        }

        #Commit changes
        Core::VultureUtils::set_memcached( 'vulture_users_in', \%users, undef,
            $mc_conf );

        #Display result in ResponseHandler
        $r->pnotes( 'response_content'      => $res );
        $r->pnotes( 'response_content_type' => 'text/plain' );

        #Destroy useless handlers
        $r->set_handlers( PerlAuthenHandler => undef );
        $r->set_handlers( PerlAuthzHandler  => undef );
        $r->set_handlers( PerlFixupHandler  => undef );
        return Apache2::Const::OK;

        #Check if user is logged in application
    }
    elsif ( $action eq 'serviceValidate' ) {
        $log->debug("Service Validate");
        my $xml =
          "<cas:serviceResponse xmlns:cas='http://www.yale.edu/tp/cas'>";
        my $errorCode  = "INVALID_TICKED";
        my $user_found = 0;

        #Check if all parameters are set
        unless (defined $ticket and defined $service ) {
            $errorCode = "INVALID_REQUEST";
        }
        else {

#Each user has an hash like { ticket => id_ticket, ticket_service => service, ticket_created => timestamp, SSO => id_session_SSO }
            while ( my ( $login, $hashref ) = each %users ) {
                my %user_hash = %$hashref;

                #Delete old ticket if too old
                if (
                    $intf->{cas_st_timeout} > 0
                    and (
                        time() - $hashref->{ticket_created} >
                        $intf->{cas_st_timeout} )
                  )
                {
                    delete $hashref->{ticket};
                    delete $hashref->{ticket_service};
                    delete $hashref->{ticket_created};
                    next;
                }

                #Check if parameter matches with stored tickets
                if (exists $user_hash{ticket}
                    and $user_hash{ticket} eq $ticket )
                {

                    #Service must match with stored service
                    if (exists $user_hash{ticket_service}
                        and $user_hash{ticket_service} ne $service )
                    {
                        $errorCode = "INVALID_SERVICE";
                    }
                    else {
			$log->debug('CAS : more field ? ' . get_cas_field($log, $dbh,$login));
                        $xml .=
"<cas:authenticationSuccess><cas:user>$login</cas:user></cas:authenticationSuccess>";
                        $user_found = 1;
                    }

                    #Unvalidate ticket
                    delete $hashref->{ticket};
                    delete $hashref->{ticket_service};
                    delete $hashref->{ticket_created};

                    last;
                }
            }
        }

        #Commit changes
        Core::VultureUtils::set_memcached( 'vulture_users_in', \%users, undef,
            $mc_conf );

        unless ($user_found) {
            $xml .=
"<cas:authenticationFailure code=\"$errorCode\"></cas:authenticationFailure>";
        }
        $xml .= "</cas:serviceResponse>";

        #Display result in ResponseHandler
        $r->pnotes( 'response_content'      => $xml );
        $r->pnotes( 'response_content_type' => 'text/xml' );

        #Destroy useless handlers
        $r->set_handlers( PerlAuthenHandler => undef );
        $r->set_handlers( PerlAuthzHandler  => undef );
        $r->set_handlers( PerlFixupHandler  => undef );
        return Apache2::Const::OK;

        #Nothing
    }
    else {
        return Apache2::Const::FORBIDDEN;
    }
}
sub get_cas_field {
    my ($log, $dbh,$login) = @_;
    my $fval = '';
    my $q1 = 'SELECT field,auth_type,id_method FROM plugin_cas,auth where auth.id = plugin_cas.auth_id ';
    my $sth   = $dbh->prepare($q1);
    $sth->execute();
    my $var = $sth->fetchrow_hashref; 
    $sth->finish();
    # No additionnal field 
    return undef unless $var;
    my $field = $var->{'field'};
    my $atype = $var->{'auth_type'};
    my $method = $var->{'id_method'};
    # field retreived from sql
    if ($atype eq 'sql'){
        my ( $new_dbh, $ref ) = get_DB_object( $log, $dbh, $method );
        if (not $new_dbh or not $ref){
            $log->debug("CAS: Unable to use to sql method");
            return undef;
        }
        my $qsql =
            "SELECT $field FROM "
          . $ref->{'table'}
          . " WHERE "
          . $ref->{'user_column'}
          . "=?";
        $log->debug("CAS (sql): $qsql");
        my $ssth = $new_dbh->prepare($qsql);
        $ssth->execute($login);
        my $result = $ssth->fetchrow;
        $ssth->finish();
        $new_dbh->disconnect();
        return $result if ($result);
        $log->debug("CAS: unable to retreive $field for $login");
        return undef;
    }
    elsif ($atype eq 'ldap'){
        return 'ldap...'; 
    }
    else{
        $log->debug('Plugin_CAS : Bad authentification method?');
        return undef;
    }
} 

1;

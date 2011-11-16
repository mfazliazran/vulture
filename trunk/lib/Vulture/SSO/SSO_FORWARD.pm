#file:SSO/SSO_FORWARD.pm
#-------------------------
package SSO::SSO_FORWARD;

use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Connection ();

use Apache2::Log;
use Apache2::Reload;

use LWP::UserAgent;
use HTTP::Request;

use Apache2::Const -compile => qw(OK REDIRECT);

use Core::VultureUtils qw(&session);
use SSO::ProfileManager qw(&get_profile &delete_profile);

use Apache::SSLLookup;
use MIME::Base64;

use APR::URI;
use APR::Table;
use APR::SockAddr;

use URI::Escape;

sub triggerAction{
    my ($r, $log, $dbh, $app, $response) = @_;
    
    my($query, $type, $options);
    $query = 'SELECT is_in_url, is_in_url_action, is_in_url_options, is_in_page, is_in_page_action, is_in_page_options FROM sso, app WHERE app.id=? AND sso.id = app.sso_forward_id';
    my $sth = $dbh->prepare($query);
	$sth->execute($app->{id});
	my ($is_in_url, $is_in_url_action, $is_in_url_options, $is_in_page, $is_in_page_action, $is_in_page_options) = $sth->fetchrow;
    $sth->finish();
    
    #Check if action is needed (grep in url, grep in page or by return code)
    if ($is_in_url and $r->unparsed_uri =~ /$is_in_url/){
        $type = $is_in_url_action;
        $options = $is_in_url_options;
    } elsif ($is_in_page and $response->as_string =~ /$is_in_page/){
        $type = $is_in_page_action;
        $options = $is_in_page_options;
        
    # Headers
    } else{
        # 10x headers
        if ($response->is_info){
            $query = 'SELECT is_info, is_info_options FROM sso, app WHERE app.id=? AND sso.id = app.sso_forward_id';
        # 20x headers
        } elsif ($response->is_success){
            $query = 'SELECT is_success, is_success_options FROM sso, app WHERE app.id=? AND sso.id = app.sso_forward_id';

        # 30x headers
        } elsif ($response->is_redirect) { 
            $query = 'SELECT is_redirect, is_redirect_options FROM sso, app WHERE app.id=? AND sso.id = app.sso_forward_id';
        
        # 40x and 50x headers
        } elsif ($response->is_error) {
            $query = 'SELECT is_error, is_error_options FROM sso, app WHERE app.id=? AND sso.id = app.sso_forward_id';
        # No action defined
        }
        
        $log->debug($query);

        $sth = $dbh->prepare($query);
        $sth->execute($app->{id});
        ($type, $options) = $sth->fetchrow;
        $sth->finish();
    }
    
    #Trigger action to do
	if($type){
        $log->debug($type.' => '.$options);
        if($type eq 'message'){
            $r->content_type('text/html');
            $r->print($options);
            return Apache2::Const::OK;
        } elsif($type eq 'log'){
            $log->debug('Response from app : '.$response->as_string);
        } elsif($type eq 'redirect'){
            $r->headers_out->set('Location' => $options);
            $r->status(302);
            return Apache2::Const::REDIRECT;
        }
    }
    
    $log->debug("Ending SSO Forward");
    $r->pnotes('SSO_Forwarding' => undef);
    $r->headers_out->add('Location' => $r->unparsed_uri);
    $r->status(302);
    return Apache2::Const::REDIRECT;
}

sub forward{
	my ($package_name, $r, $log, $dbh, $app, $user, $password) = @_;

    my $r = Apache::SSLLookup->new($r);

	my (%session_app);
	session(\%session_app, undef, $r->pnotes('id_session_app'), $log, $app->{update_access_time});

    my %headers_vars = (
		    2 => 'SSL_CLIENT_I_DN',
		    3 => 'SSL_CLIENT_M_SERIAL',
		    4 => 'SSL_CLIENT_S_DN',
		    5 => 'SSL_CLIENT_V_START',
		    6 => 'SSL_CLIENT_V_END',
		    7 => 'SSL_CLIENT_S_DN_C',
		    8 => 'SSL_CLIENT_S_DN_ST',
		    9 => 'SSL_CLIENT_S_DN_Email',
		    10 => 'SSL_CLIENT_S_DN_L',
		    11 => 'SSL_CLIENT_S_DN_O',
		    12 => 'SSL_CLIENT_S_DN_OU',
		    13 => 'SSL_CLIENT_S_DN_CN',
		    14 => 'SSL_CLIENT_S_DN_T',
		    15 => 'SSL_CLIENT_S_DN_I',
		    16 => 'SSL_CLIENT_S_DN_G',
		    17 => 'SSL_CLIENT_S_DN_S',
		    18 => 'SSL_CLIENT_S_DN_D',
		    19 => 'SSL_CLIENT_S_DN_UID',
		   );

	$log->debug("########## SSO_FORWARD ##########");

	$log->debug("LWP::UserAgent is emulating post request on ".$app->{name});

	#Getting SSO type
	$log->debug("Getting data from database");
	my $query = "SELECT sso.type FROM sso, app WHERE app.id=? AND sso.id = app.sso_forward_id";
    $log->debug($query);

	my $sth = $dbh->prepare($query);
	$sth->execute($app->{id});
	my ($sso_forward_type) = $sth->fetchrow;
	$sth->finish();
	$log->debug("SSO_FORWARD_TYPE=".$sso_forward_type);

	my $post = '';
	#Getting fields from profile
    #URI encoding is needed
	my %results = %{get_profile($r, $log, $dbh, $app, $user)};
	if (%results){
	    while (($key, $value) = each(%results)){
	        $post .= uri_escape($key)."=".uri_escape($value)."&";
	    }
    }

    #Getting specials fields like "autologon_*"
    $query = "SELECT field_var, field_type, field_encrypted, field_value FROM field, sso, app WHERE field.sso_id = sso.id AND sso.id = app.sso_forward_id AND app.id=? AND (field_type = 'autologon_password' OR field_type = 'autologon_user' OR field_type = 'hidden')";
	$log->debug($query);
    my $sth = $dbh->prepare($query);
	$sth->execute($app->{id});

	#Adding data to post variable
    #URI encoding is needed
	my $ref = $sth->fetchall_arrayref;
    $sth->finish();
	foreach my $row (@{$ref}) {
        my ($var, $type, $need_decryption, $value) = @$row;
		if($type eq 'autologon_user'){
            $post .= uri_escape($var)."=".uri_escape($user)."&";
        } elsif($type eq 'autologon_password'){
            $post .= uri_escape($var)."=".uri_escape($password)."&";
        } else {
		    if($need_decryption){
		        $log->debug("Decrypting $var");
                $value = decrypt($value);
		    }
            $post .= uri_escape($var)."=".uri_escape($value)."&";        
        }
	}
    $sth->finish();
    $log->debug("Due to CONFIDENTIALITY REASONS, posted string have been removed from debug");

	#Setting browser
	my ($ua, $response, $request);
	$ua = LWP::UserAgent->new;

	#Setting proxy if needed
	if ($app->{remote_proxy} ne ''){
		$ua->proxy(['http', 'https'], $app->{remote_proxy});
	}

	#Setting request
	$request = HTTP::Request->new('POST', $app->{url}.$app->{logon_url}, undef, $post);

	#Setting headers
	$request->push_header('Content-Type' => 'application/x-www-form-urlencoded');
	$request->push_header('User-Agent' => $r->headers_in->{'User-Agent'});
	
	my $parsed_uri = APR::URI->parse($r->pool, $app->{'url'});
    my $host = $parsed_uri->hostname ;
    $request->push_header('Host' => $host);
	#$request->push_header('Host' => $app->{url}.':'.$app->{port});
	
    if (defined($r->headers_in->{'Max-Forwards'})) {
        $request->push_header('Max-Forwards' => $r->headers_in->{'Max-Forwards'} - 1);
    } else {
        $request->push_header('Max-Forwards' => '10');
    }
    if (defined($r->headers_in->{'X-Forwarded-For'})) {
        $request->push_header('X-Forwarded-For' => $r->headers_in->{'X-Forwarded-For'}.", ".$r->connection->remote_ip);
    } else {
        $request->push_header('X-Forwarded-For' => $r->connection->remote_ip);
    }

    $request->push_header('X-Forwarded-Host' => $r->hostname());
    $request->push_header('X-Forwarded-Server' => $r->hostname());
			       

    #Getting custom headers defined in admin
    my $sth = $dbh->prepare("SELECT name, type, value FROM header WHERE app_id='".$app->{id}."'");
    $sth->execute;
    while (my ($name, $type, $value) = $sth->fetchrow) {
        if ($type eq "REMOTE_ADDR"){
	        $value = $r->connection->remote_ip;
        } elsif ($type eq "CUSTOM"){
        } else {
            $value = $r->ssl_lookup($headers_vars{$type}) if (exists $headers_vars{$type});
        }
        
        #Try to push custom headers
        eval {
            $request->push_header($name => $value);
            $log->debug("Pushing custom header $name => $value");
        };
	}
    $sth->finish();

    #Sending Authorization header if needed by SSO forward type
    if($sso_forward_type eq 'sso_forward_htaccess'){
        $request->push_header('Authorization' => "Basic " . encode_base64($user.':'.$password));    
    }

	#Make request and get response
	$response = $ua->request($request);
    $log->debug("Due to CONFIDENTIALITY REASONS, response have been removed from debug");	

	#Cookie coming from response
	my %cookies_app;
	if ($response->headers->header('Set-Cookie')){
		# Adding new couples (name, value) thanks to POST response
		foreach ($response->headers->header('Set-Cookie')) {
			if (/([^,; ]+)=([^,; ]+)/) {
				$cookies_app{$1} = $2;		# adding/replace
				$log->debug("ADD/REPLACE ".$1."=".$2);
				
			}
		}
        
        #Fill session with cookies returned by app (for logout)
		$session_app{cookie} = $response->headers->header('Set-Cookie');
	}
	foreach my $k (keys %cookies_app){
		$r->err_headers_out->add('Set-Cookie' => $k."=".$cookies_app{$k}."; domain=".$r->hostname."; path=/");  # Send cookies to browser's client
		$log->debug("PROPAG ".$k."=".$cookies_app{$k});
	}
    
    #trigger action needed
    return triggerAction($r, $log, $dbh, $app, $response);
}
1;
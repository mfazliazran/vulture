#file:Core/ResponseHandlerv2.pm
#---------------------------------
package Core::ResponseHandlerv2;

use Apache2::Access ();
use Apache2::Reload;
use Apache2::RequestUtil ();
use Apache2::Log;

use DBI;

use Apache2::Const -compile => qw(OK DECLINED REDIRECT HTTP_UNAUTHORIZED);

use Core::VultureUtils qw(&session &getStyle &getTranslations &generate_random_string);
use SSO::ProfileManager qw(&getProfile);

use Apache::SSLLookup;

use Module::Load;

sub handler {
  	my $r = Apache::SSLLookup->new(shift);

	my $log = $r->pnotes('log');
	
	#Getting data from pnotes
	my $app = $r->pnotes('app');
	my $dbh = $r->pnotes('dbh');

	#$user may not be set if Authentication is done via Apache (ex: mod_auth_kerb)
	my $user = $r->pnotes('username') || $r->user;
	my $password = $r->pnotes('password');

	my (%session_app);
	session(\%session_app, $app->{timeout}, $r->pnotes('id_session_app'), $log, $app->{update_access_time});
	my (%session_SSO);
	session(\%session_SSO, $app->{timeout}, $r->pnotes('id_session_SSO'), $log, $app->{update_access_time});

	#Query counter
	#my $query = "UPDATE stats SET value=value+1 WHERE var='responsehandler_counter'";
	#$log->debug($query);
	#$dbh->do($query) or $log->error($dbh->errstr);

	$log->debug("########## ResponseHandlerv2 ##########");
       	    
	#Bypass everything to display custom message (ex : custom auth)
	if($r->pnotes('response_content') or $r->pnotes('response_headers') or $r->pnotes('response_content_type')){
	    $log->debug("Bypass ResponseHandler because we have a response to display");
		if($r->pnotes('response_headers')){
			my @headers = split /\n/, $r->pnotes('response_headers');
			
            foreach my $header (@headers){
                $log->debug('Parse header');
				if($header =~ /^([^:]+):(.*)$/){
                    $log->debug('Find header '.$1.' => '.$2);
					$r->err_headers_out->set($1 => $2);
				}
			}
            $r->status(Apache2::Const::REDIRECT);
		}
		$r->print($r->pnotes('response_content')) if defined $r->pnotes('response_content');
		$r->content_type($r->pnotes('response_content_type')) if defined $r->pnotes('response_content_type');
        
        #Force headers to be send out
        $r->rflush;
		return Apache2::Const::OK;
	}

	#SSO Forwarding
	if(exists $session_app{SSO_Forwarding}){
		if(defined $session_app{SSO_Forwarding}){
			my $module_name = "SSO::SSO_".uc($session_app{SSO_Forwarding});

			load $module_name;
			
			#Get return
			$module_name->forward($r, $log, $dbh, $app, $user, $password);
		}
		delete $session_app{SSO_Forwarding};
		$session_app{SSO_Forwarding} = $r->pnotes('SSO_Forwarding') if defined $r->pnotes('SSO_Forwarding');

		return Apache2::Const::OK;
	}
	
	#If user is logged, then redirect
	if($user){

		#SSO Forwarding once
		if(not defined $session_app{SSO_Forwarding} and $app->{sso_forward}){
			#If results are the same, it means user has already complete the SSO Learning phase
			my $query = "SELECT count(*) FROM field, sso, app WHERE field.sso_id = sso.id AND sso.id = app.sso_forward_id AND app.id=? AND field_type != 'autologon_password' AND field_type != 'autologon_user' AND field_type != 'hidden'";
			$log->debug($query);
            my $href = SSO::ProfileManager::getProfile($r, $log, $dbh, $app, $user);
            
			my $length1 = $dbh->selectrow_array($query, undef, $app->{id});
            my $length2 = keys %$href;

            my $query_type = "SELECT sso.type FROM sso, app WHERE app.id = ? AND sso.id = app.sso_forward_id";
            $log->debug($query_type);
			my $type = $dbh->selectrow_array($query_type, undef, $app->{id});

            #Learning ok or no need of learning
            if ($length1 == 0 or $type eq 'sso_forward_htaccess' or $length2 == $length1){
                $log->debug("Getting pass for SSO Forward");
                $session_app{SSO_Forwarding} = 'FORWARD';

            #Learning was not done yet
            } else {
                $log->debug("Getting pass for SSO Learning");
                $session_app{SSO_Forwarding} = 'LEARNING';
            }
		}
        #Display portal instead of redirect user
	    if($app->{display_portal}){
            $log->debug("Display portal with all applications");
		    #Getting all app info
            my $portal = display_portal($r,$log, $dbh, $app);
		    $r->content_type('text/html');
		    $r->print($portal);
		    return Apache2::Const::OK;
		    
        } elsif(defined($session_app{url_to_redirect})) {
            #Redirect user
		    $r->status(200);
            my $incoming_uri = $app->{name};
            if ($incoming_uri !~ /^(http|https):\/\/(.*)/ ) {
                #Fake scheme for making APR::URI parse
                $incoming_uri = 'http://'.$incoming_uri;
            }
            #Rewrite URI with scheme, port, path,...
            my $rewrite_uri = APR::URI->parse($r->pool, $incoming_uri);
                
            $rewrite_uri->scheme('http');
            $rewrite_uri->scheme('https') if $r->is_https;
            $rewrite_uri->port($r->get_server_port());
            my $path = $session_app{url_to_redirect};
            $rewrite_uri->path($path);
		    $r->err_headers_out->set('Location' => $rewrite_uri->unparse);
		    $log->debug('Redirecting to '.$rewrite_uri->unparse);

		    return Apache2::Const::REDIRECT;

        } elsif(defined $r->pnotes('url_to_redirect')){
            $r->status(200);

		    my $url = $r->pnotes('url_to_redirect');
		    $r->err_headers_out->set('Location' => $url);
		    $log->debug('Redirecting to '.$url);

		    return Apache2::Const::REDIRECT;

        } else {
            my $html = "<html><head><title>Successful login</title></head><body>You are successfull loged on SSO</body></html>";
            $r->print($html);
            $r->content_type('text/html');
            return Apache2::Const::OK;
        }
    
    #No user set before. Need to display Vulture auth
	} else {
        #Display Vulture auth
        if($app and !$app->{'auth_basic'} and not $r->pnotes('static')) {
	        $log->debug("Display auth form");
	        $r->content_type('text/html');
	        $r->print(display_auth_form($r, $log, $dbh, $app));
	        return Apache2::Const::OK;
        }
	    $log->debug("Serving static file");
    }
	return Apache2::Const::DECLINED;
}

sub display_auth_form {
	my ($r, $log, $dbh, $app) = @_;
	
	#CAS
	my $req = Apache2::Request->new($r);	
	my $service = $req->param('service');
	#END CAS
    
	my $uri = $r->unparsed_uri;
	my $message = $r->pnotes("auth_message");    
    my $translated_message;

    #Get session SSO for filling random token
    my (%session_SSO);
    session(\%session_SSO, $app->{timeout}, $r->pnotes('id_session_SSO'), $log, $app->{update_access_time});

	#if($r->unparsed_uri =~ /vulture_app=([^;]*)/){
	#	$uri = $1;
	#}
    
    #Get translations
    my $translations = getTranslations($r, $log, $dbh, $message);
    
    #Avoid bot request (token)
    my $token = generate_random_string(32);
    $session_SSO{random_token} = $token;
    
    #Get style
    my $form = "<div id=\"form_vulture\"><form method=\"POST\" name=\"auth_form\" action=\"$uri\"><table>";
    $form .= "<tr class=\"row\"><td></td><td class=\"hidden\" name=\"service\" value=\"$service\"></td></tr>" if defined $service;
    $form .= <<FOO
<tr class="row"><td class="input">$translations->{'USER'}{'translation'}</td><td><input type="text" name="vulture_login"></td></tr>
<tr class="row"><td class="input">$translations->{'PASSWORD'}{'translation'}</td><td><input type="password" autocomplete="off" name="vulture_password"></td></tr>
<tr class="row"><td></td><td align="right"><input type="hidden" name="vulture_token" value="$token"></td></tr>
<tr class="row"><td></td><td align="right"><input type="submit"></td></tr>
</table>
</form>
</div>
FOO
;

	return getStyle($r, $log, $dbh, $app, 'LOGIN', 'Please authenticate', {FORM => $form, ERRORS => $translations->{$message}{'translation'}}, $translations);
}

sub display_portal {
	my ($r,$log,$dbh, $app) = @_;

    my $intf_id = $r->dir_config('VultureID');
	my $query = "SELECT app.name FROM app, app_intf WHERE app_intf.intf_id='$intf_id' AND app.id = app_intf.app_id";
    $log->debug($query);

    my $all_apps = $dbh->selectall_arrayref($query);
    
    #Get translations
    my $translations = getTranslations($r, $log, $dbh, 'APPLICATION');
    
    #Get all apps
    my $html_apps = "<ul>";
    foreach my $app (@$all_apps) {
        my $incoming_uri = @$app[0];
        if ($incoming_uri !~ /^(http|https):\/\/(.*)/ ) {
            #Fake scheme for making APR::URI parse
            $incoming_uri = 'http://'.$incoming_uri;
        }
        #Rewrite URI with scheme, port, path,...
        my $rewrite_uri = APR::URI->parse($r->pool, $incoming_uri);
            
        $rewrite_uri->scheme('http');
        $rewrite_uri->scheme('https') if $r->is_https;
        $rewrite_uri->port($r->get_server_port());
        $html_apps .= "<li><a href='".$rewrite_uri->unparse."'><h3>Application ".@$app[0]."</h3></a></li>";
    }
    $html_apps .= "</ul>";
    
    #Get style
    my $html = getStyle($r, $log, $dbh, $app, 'PORTAL', 'SSO portal', {APPS => $html_apps}, $translations);
    return $html =~ /<body>.+<\/body>/ ? $html : $html_apps;
}

1;
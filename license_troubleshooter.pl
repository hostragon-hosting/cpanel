#!/usr/local/cpanel/3rdparty/bin/perl
# SCRIPT: cplicensets
# PURPOSE: Run some tests to (hopefully) quickly determine what may be causing a cPanel
#		license failure.  Taken from the steps outlined at:
# 		https://cpanel.wiki/display/LS/License+Troubleshooting
# CREATED: 3/23/2016
# AUTHOR: Peter Elsner <peter.elsner@cpanel.net>
#

BEGIN {
    unshift @INC, '/usr/local/share/perl5';
    unshift @INC, '/usr/local/lib/perl5';
}

use strict;
use Socket;
use IO::Socket::INET;
use Time::HiRes qw( clock_gettime CLOCK_REALTIME );
use Sys::Hostname;
use Getopt::Long;
use Term::ANSIColor qw(:constants);
use Cpanel::Config::LoadWwwAcctConf ();
use Cpanel::Validate::Hostname;
use Cpanel::Validate::IP;

my $version = "1.27";

$Term::ANSIColor::AUTORESET = 1;
$|                          = 1;

my ($skipdate);
my ($withlogs);
my ($verifypage);
GetOptions(
    "skipdate"   => \$skipdate,
    "withlogs"   => \$withlogs,
    "verifypage" => \$verifypage,
);

our $CPANEL_LICENSE_FILE = '/usr/local/cpanel/cpanel.lisc';
my $file_is_solo             = license_file_is_solo();
my $file_is_dnsonly          = license_file_is_dnsonly();
my $file_is_cpanel           = license_file_is_cpanel();
my $file_is_cloudlinux       = license_file_is_cloudlinux();
my $license_ip               = license_file_ip();
my $license_expire_time      = license_file_expire();
my $updates_expire_time      = license_file_updates_expire();
my $support_expire_time      = license_file_support_expire();
my $json;
my $tried_import;

print "<c>\n";
print "cPanel License Troubleshooter - Version: $version\n\n";
check_for_centOS5();
print BOLD MAGENTA "Additional options:\n\n--skipdate skips date check\n";
print BOLD MAGENTA "--withlogs displays last 50 lines of license_log file\n";
print BOLD MAGENTA
  "--verifypage show verify.cpanel.net page in JSON format.\n\n";

&module_sanity_check();

our $HOSTNAME;
our $mainip;
our $envtype;
our $MAC;
our $HOSTNAME_IP;
our $EXTERNAL_IP_ADDRESS_80 = determine_ip(80);
our $timenow                = time();

is_license_valid();
chk_for_lisclock();
check_for_trial();
is_hostname_fqdn();
check_hostsfile();
check_for_accountinglog();
get_envtype();
get_mainip();
get_ipinfo($EXTERNAL_IP_ADDRESS_80);
get_wwwacctconf_ip();
get_logStats();
get_devices();
run_check_valid_server_hostname();
check_kernel_hostname();
display_etc_hostname();
get_network_hostname();
get_ip_of_hostname();
get_reverse_of_ip();
check_file_for_odd_chars("/etc/hosts");
check_file_for_odd_chars("/etc/sysconfig/network");
check_if_hostname_resolves_locally();
check_resolvconf();
check_for_cloudcfg();
check_for_license_error();
get_hostname_at_install();
check_for_hostname_changes();
check_for_cpkeyclt_from_cli();
shenanigans();
check_routing();
check_for_cpnat();
check_cron_log();
check_root_servers();
is_ntpd_installed();

if ( !($skipdate) ) {
    get_date();
}
check_auth_cpanel_resolution();
check_iptables();
check_etc_mtab_file();
check_other_ports();
check_perms_on_cpanel_lisc_file();
if ( -e ( "/usr/local/cpanel/cpanel.lisc" or ( -e ("/usr/local/cpanel/cpsanitycheck.so") ))) {
    print_working("Checking immutable files: ");
    print "\n";
    is_file_immutable("/usr/local/cpanel/cpanel.lisc");
    is_file_immutable("/usr/local/cpanel/cpsanitycheck.so");
    is_lisc_lockable();
}
run_rdate();
chkCreds();
display_route();
get_cpsrvd_restarts();
get_last_reboots();
if ($verifypage) {
    getVerifyJSON();
}

if ($withlogs) {
    read_last_50_lines_of_license_log();
}

print "</c>\n";
exit;

sub determine_ip {
    my $port = $_[0];
    print_working("Obtaining the external IP address (port $port): ");
    my $EXTERNAL_IP_ADDRESS = get_external_ip($port);
    print_OK($EXTERNAL_IP_ADDRESS) unless !($EXTERNAL_IP_ADDRESS);
    print "\n" unless !($EXTERNAL_IP_ADDRESS);
    return $EXTERNAL_IP_ADDRESS;
}

sub is_hostname_fqdn {
    $HOSTNAME = hostname();
    print_working(
        "Verifying if hostname (" . $HOSTNAME . ") is a valid FQDN: " );
    if ( $HOSTNAME !~ /([\w-]+)\.([\w-]+)\.(\w+)/ ) {
        print_warn("Error - hostname ($HOSTNAME) is not a valid FQDN!");
    }
    else {
        print_OK("Valid!");
        print "\n";
    }
}

sub is_license_valid {
    print_working( "Verifying if $EXTERNAL_IP_ADDRESS_80 has a valid license: ");
    my $host       = 'verify.cpanel.net';
    my $helper_url = "https://" . $host;
    my $url        = '/index.cgi?ip=' . $EXTERNAL_IP_ADDRESS_80;
    $helper_url .= $url;
    my $sock = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => 80,
        Proto    => 'tcp',
        Timeout  => 5,
    ) or return;
    local $SIG{'ALRM'} = sub { return (); };
    alarm 5;
    print $sock "GET ${url} HTTP/1.1\r\nHost: ${host}\r\n\r\n";
    read $sock, my $buffer, 20_000;
    alarm 0;
    close $sock;

    if ( $buffer =~ m/active<br\/>/ ) {
        print_OK("Active!");
        print "\n";
		print YELLOW "\t \\_ https://verify.cpanel.net/index.cgi?ip=$EXTERNAL_IP_ADDRESS_80\n";
#        print "\n";
		if (-e($CPANEL_LICENSE_FILE)) {
    		print BOLD YELLOW "Licensed for IP: " . BOLD GREEN $license_ip . "\n";
			chomp($license_expire_time);
    		print BOLD YELLOW "License Expires On: " . BOLD GREEN scalar localtime($license_expire_time) . "\n";
            if ( $timenow > $license_expire_time ) {
                print_warn(" EXPIRED!");
            }
		    print BOLD YELLOW "Solo License: " . BOLD GREEN $file_is_solo . "\n";
    		print BOLD YELLOW "DNSOnly license: " . BOLD GREEN $file_is_dnsonly . "\n";
    		print BOLD YELLOW "Licensed for cPanel: " . BOLD GREEN $file_is_cpanel . "\n";
    		print BOLD YELLOW "Licensed for CloudLinux: " . BOLD GREEN $file_is_cloudlinux . "\n";
    		print BOLD YELLOW "License Expires On: " . BOLD GREEN scalar localtime($license_expire_time) . "\n";
            if ( $timenow > $license_expire_time ) {
                print_warn(" EXPIRED!");
            }
    		print BOLD YELLOW "Updates Expires On: " . BOLD GREEN scalar localtime($updates_expire_time) . "\n" unless($updates_expire_time ==0);
    		print BOLD YELLOW "Support Expires On: " . BOLD GREEN scalar localtime($support_expire_time) . "\n" unless($support_expire_time ==0);
		}
		else {
    		print "cpanel.lisc file missing!\n";
		}
        return;
    }
    if ( $buffer =~ m/expired on<br\/>/ ) {
        print_warn("Expired! - Send ticket to customer service");
		print RED "\t \\_ https://verify.cpanel.net/index.cgi?ip=$EXTERNAL_IP_ADDRESS_80\n";
        return;
    }
}

sub get_external_ip {
    my ($port) = @_;
    die "get_external_ip port number not specified" if !$port;

    # myip.cpanel.net supports HTTP ports 80, 2089 and HTTPS port 443.
    my $host = 'myip.cpanel.net';
    my $path = '/v1.0/';
    my $ip;
    my $reply;
    my $count = 0;
    for ( 1 .. 2 ) {
        local $SIG{'ALRM'} = sub {
            $count++;
            print_warn("Timed out: ");
        };
        alarm 5;
        my $sock = IO::Socket::INET->new(
            PeerAddr => $host,
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 5,
        );
        if ($sock) {
            print $sock "GET ${path} HTTP/1.1\r\nUser-Agent: cPanel/"
              . $version
              . "\r\nHost: ${host}\r\n\r\n";
            sysread $sock, $reply, 1500;
            close $sock;
        }
        alarm 0;
        if ( $reply and $reply =~ m{ ^ \s* (\d+\.\d+\.\d+\.\d+) \s* $ }xms ) {
            $ip = $1;
            chomp $ip;
            return $ip;
        }
    }
}

sub module_sanity_check {
    my @required_mods = qw( IO::Socket::PortState IO::Interface::Simple );
    my $reqmod;
    print_working("Checking if required Perl Modules are installed:\n");
    foreach $reqmod (@required_mods) {
        eval("use $reqmod");
        if ($@) {
            print_warn( "\t \\_ " . $reqmod . " No - Installing!" );
            my $modinstall =
              qx[ /usr/local/cpanel/bin/cpanm $reqmod 2> /dev/null ];
        }
        else {
            print_OK( "\t \\_ " . $reqmod . " OK!" );
            print "\n";
        }
    }
}

sub print_working {
    my $text = shift;
    print BOLD YELLOW ON_BLACK . $text;
}

sub print_warn {
    my $text = shift;
    print BOLD RED ON_BLACK . $text . "\n";
}

sub print_OK {
    my $text = shift;

    #print BOLD GREEN ON_BLACK . $text . "\n";
    print BOLD GREEN ON_BLACK . $text;
}

sub system_formatted {
    open( my $cmd, "-|", "$_[0]" );
    while (<$cmd>) {
        print_formatted("$_");
    }
    close $cmd;
}

sub print_formatted {
    my @input = split /\n/, $_[0];
    foreach (@input) { print "    $_\n"; }
}

sub check_kernel_hostname {
    print_working(
        "Verifying if sysctl kernel.hostname matches " . $HOSTNAME . ": " );
    my $KERN_HOSTNAME =
      qx [ sysctl kernel.hostname | cut -d = -f2 2> /dev/null ];
    $KERN_HOSTNAME = alltrim($KERN_HOSTNAME);
    if ( $KERN_HOSTNAME eq $HOSTNAME ) {
        print_OK("Valid!");
        print "\n";
    }
    else {
        print_warn("Failed!");
    }
}

sub display_etc_hostname {
    print_working("Checking for /etc/hostname file: ");
    if ( -e ("/etc/hostname") ) {
        my $etchostname = qx[ cat /etc/hostname ];
        chomp($etchostname);
        print_OK($etchostname);
        if ( $etchostname ne $HOSTNAME ) {
            print RED "\n\t \\_ [WARN] does not match hostname! ($HOSTNAME)";
        }
        print "\n";
    }
    else {
        print_warn("None Found");
    }
}

sub get_network_hostname {
    print_working("HOSTNAME from /etc/sysconfig/network: ");
    my $networkhost = qx[ grep '^HOSTNAME=' /etc/sysconfig/network ];
    chomp($networkhost);
    print_OK($networkhost);
    print "\n";
}

sub alltrim() {
    my $string2trim = $_[0];
    $string2trim =~ s/^\s*(.*?)\s*$/$1/;
    return $string2trim;
}

sub get_devices {
    my $device;
    my $deviceline;
	my $nicIP;
    print_working("Obtaining NIC Devices:\n");
    my @DEVICES = qx[ ip -o link show ];
    foreach $deviceline (@DEVICES) {
        chomp($deviceline);
        next if ($deviceline =~ /DOWN/);
        ($device) = ( split( /\s+/, $deviceline ) )[1];
        chop($device);    ## Remove trailing colon
        if ( $device eq "lo" ) { next; }
		if ( $device eq "venet0" ) { $device = "venet0:0"; }
        if ( -e ("/etc/sysconfig/network-scripts/ifcfg-$device") ) {
            my $if = IO::Interface::Simple->new($device);
			$nicIP = $if->address;
            print BOLD MAGENTA ON_BLACK
              . "\t \\_ Ethernet Device Name: "
              . CYAN $device . "\n";
            print BOLD YELLOW . "\t\t \\_ Address: " . CYAN $nicIP . "\n";
            my $MACVendor = getMAC( $if->hwaddr );
            print BOLD YELLOW
              . "\t\t \\_ MAC: "
              . CYAN $if->hwaddr . " ["
              . $MACVendor . "]\n";
            print BOLD YELLOW
              . "\t\t \\_ Broadcast: "
              . CYAN $if->broadcast . "\n";
            print BOLD YELLOW . "\t\t \\_ Netmask: " . CYAN $if->netmask . "\n";
            print BOLD YELLOW . "\t\t \\_ MTU: " . CYAN $if->mtu . "\n";
            arping_check($device,$nicIP);
            check_for_multiple_defroute($device);

            if ( $device eq "eth0" and $nicIP eq "" ) {
                print_warn(
"Device eth0 has no address - Seeing Waiting for devices to settle errors in license_log?"
                );
            }
            check_for_dhcp($device);
        }
    }
}

sub get_ip_of_hostname {
    print_working("Obtaining the IP for hostname $HOSTNAME: ");
    my $OK;
    my $HOSTNAME_IP = qx[ dig \@208.67.222.222 $HOSTNAME +short 2>/dev/null ];
    chomp($HOSTNAME_IP);
    my $IPValid = Cpanel::Validate::IP::is_valid_ipv4($HOSTNAME_IP);
    if ($IPValid) {
        $OK = 1;
    }
    else {
        $OK = 0;
    }
    if ( $HOSTNAME_IP eq $EXTERNAL_IP_ADDRESS_80 and $IPValid ) {
        $OK = 1;
    }
    else {
        $OK = 0;
    }
    if ($OK) {
        print BOLD GREEN $HOSTNAME_IP;
        print_OK(" - Good");
        print "\n";
    }
    else {
        if ($HOSTNAME_IP) {
            print_warn("Failed! ($HOSTNAME_IP)");
        }
        else {
            print_warn("Failed! (NXDOMAIN)");
        }
    }
    print BOLD YELLOW "\t \\_ Hostname IP: "
      . CYAN $HOSTNAME_IP
      . YELLOW " / External IP Address: "
      . CYAN $EXTERNAL_IP_ADDRESS_80 ;
    if ( $HOSTNAME_IP ne $EXTERNAL_IP_ADDRESS_80 ) {
        print RED " [WARN]\n";
    }
    else {
        print GREEN " [OK]\n";
    }
}

sub get_reverse_of_ip {
    return if !($HOSTNAME_IP);
    print_working("Reversing IP ($HOSTNAME_IP) ");
    if ($HOSTNAME_IP) {
        my $REVERSED_IP =
          qx[ dig \@208.67.220.220 -x $HOSTNAME_IP +short 2>/dev/null ];
        chomp($REVERSED_IP);
        if ($REVERSED_IP) {
            print_OK($REVERSED_IP);
            print "\n";
        }
        else {
            print_warn("Failed!");
        }
    }
}

sub check_file_for_odd_chars {
    my $TheFile = $_[0];
    my $line;
    my @invalid;
    my $invalid;
    return if !-e $TheFile;
    print_working("Checking $TheFile for non-ascii characters ");
    open( HOSTS, $TheFile );
    my @DATA = <HOSTS>;
    close(HOSTS);
    my @invalid = undef;
    my $cnt     = 0;

    foreach $line (@DATA) {
        chomp($line);
        if ( $line =~ /[^!-~\s]/g ) {
            push( @invalid, "$line contains ($&)" );
        }
    }
    $cnt = @invalid;
    $cnt--;
    if ( $cnt > 0 ) {
        print_warn(
"There are $cnt lines in $TheFile that contain non-ascii characters: "
        );
        foreach $invalid (@invalid) {
            chomp($invalid);
            print "$invalid\n";
        }
    }
    else {
        print_OK("All Good");
        print "\n";
    }
}

sub check_if_hostname_resolves_locally {
    print_working("Does $HOSTNAME resolve locally: ");
    my $LOCAL_HOSTNAME_IP = qx[ dig $HOSTNAME +short 2>/dev/null ];
    chomp($LOCAL_HOSTNAME_IP);
    if ($LOCAL_HOSTNAME_IP) {
        print_OK("Yes - ($LOCAL_HOSTNAME_IP)");
        print "\n";
    }
    else {
        print_warn("No");
        return;
    }

    # If $LOCAL_HOSTNAME_IP is not a valid IP address, skip this step.
    my $OK;
    my $IPValid = Cpanel::Validate::IP::is_valid_ipv4($LOCAL_HOSTNAME_IP);
    if ($IPValid) {
        print_working("Does $LOCAL_HOSTNAME_IP reverse back to $HOSTNAME: ");
        my $LOCAL_HOSTNAME_REVERSED =
          qx[ dig -x $LOCAL_HOSTNAME_IP +short 2>/dev/null ];
        chomp($LOCAL_HOSTNAME_REVERSED);
        chop($LOCAL_HOSTNAME_REVERSED);
        if ( $LOCAL_HOSTNAME_REVERSED eq $HOSTNAME ) {
            print_OK("Yes");
            print "\n";
        }
        else {
            print_warn("No");
        }
    }
    else {
        print_warn("IP Address validation failed for $LOCAL_HOSTNAME_IP!");
    }
}

sub check_for_license_error {
    print_working("Checking for license error: ");
    if ( -e ("/usr/local/cpanel/logs/license_error.display") ) {
        print "\n";
        open( LICERR, "/usr/local/cpanel/logs/license_error.display" );
        my @LICERR = <LICERR>;
        my $errline;
        close(LICERR);
        foreach $errline (@LICERR) {
            chomp($errline);
            print "$errline\n";
            if ( $errline =~ m/activated too many times on different machines/ )
            {
                print "\n";
                print_warn(
"*******************************************************************"
                );
                print_warn(
"************************* ESCALATE TO L3! *************************"
                );
                print_warn(
"*******************************************************************"
                );
            }
        }
        print "\n";
    }
    else {
        print_OK("None");
        print "\n";
    }
}

sub get_hostname_at_install {
    return if !-e "/var/log/cpanel-install.log";
    print_working("Hostname at time of cPanel install was: ");
    my $HOSTNAME_AT_INSTALL =
qx[ grep 'Validating that the system hostname' /var/log/cpanel-install.log | cut -d \" \" -f12 | cut -d \"\'\" -f2 2> /dev/null ];
    chomp($HOSTNAME_AT_INSTALL);
    if ( !($HOSTNAME_AT_INSTALL) ) {
        print_warn("Unknown");
    }
    else {
        print_OK($HOSTNAME_AT_INSTALL);
        print "\n";
    }
}

sub check_for_hostname_changes {
    print_working("Checking access_log for hostname changes: \n");
    my $allhostnames;
    my $histline;
    my @HOSTNAME_CHANGES;
    my $histchange;
    my $hostname_change;
    my $hostname_date_change1;
    my $hostname_date_change2;
    my @accesslog_hostnames =
      qx[ grep 'dochangehostname?hostname' /usr/local/cpanel/logs/access_log ];
    my $alhostcnt = @accesslog_hostnames;
    if ( $alhostcnt == 0 ) {
        print BOLD CYAN "\t \\_ None Found.\n";
    }
    foreach $allhostnames (@accesslog_hostnames) {
        chomp($allhostnames);
        ($hostname_change) = ( split( /\s+/, $allhostnames ) )[6];
        ( $hostname_date_change1, $hostname_date_change2 ) =
          ( split( /\s+/, $allhostnames ) )[ 3, 4 ];
        ($hostname_change) = ( split( /=/, $hostname_change ) )[1];
        if ($hostname_change) {
            print YELLOW "\t \\_ Changed to: "
              . BOLD GREEN $hostname_change
              . YELLOW " on "
              . BOLD GREEN $hostname_date_change1 . " "
              . $hostname_date_change2 . "\n"
              unless ( $hostname_change eq "1" );
        }
    }
    print_working("Checking /root/.bash_history for hostname changes: \n");
    open( HIST, "/root/.bash_history" );
    my @HISTORY = <HIST>;
    close(HIST);
    my @hostchangeHist;
    my $histtime;
    foreach $histline (@HISTORY) {
        chomp($histline);
        if ( substr( $histline, 0, 1 ) eq "#" ) {
            $histtime = substr( $histline, 1 );
        }
        if ( $histline =~ m/\/usr\/local\/cpanel\/bin\/set_hostname / ) {
            print YELLOW "\t \\_ On "
              . BOLD GREEN scalar localtime($histtime) . " - "
              . $histline . "\n"
              unless ( $histline =~
                m/grep|vim \/etc\/hostname|vi \/etc\/hostname|rm/ );
        }
        if ( $histline =~ m/hostnamectl set-hostname/ ) {
            print YELLOW "\t \\_ On "
              . BOLD GREEN scalar localtime($histtime) . " - "
              . $histline . "\n"
              unless (
                $histline =~ m/grep|vim \/etc\/hostname|vi \/etc\/hostname|rm/
                or $histline =~ m/set_hostname/ );
        }
        if ( $histline =~ m/hostname / ) {
            print YELLOW "\t \\_ On "
              . BOLD GREEN scalar localtime($histtime) . " - "
              . $histline . "\n"
              unless (
                $histline =~ m/grep|vim \/etc\/hostname|vi \/etc\/hostname|rm/
                or $histline =~ m/set_hostname/
                or $histline =~ m/set-hostname/ );
        }
    }
	print_working("Checking /var/log/messages for hostname changes: \n");
	my $messhost;
	my @messlogRestarts = qx[ grep 'systemd-hostnamed: Changed host name to' /var/log/messages ];
    my $messcnt = @messlogRestarts;
    if ( $messcnt == 0 ) {
        print BOLD CYAN "\t \\_ None Found.\n";
    }
	else { 
		foreach $messhost(@messlogRestarts) { 
			chomp($messhost);
			print YELLOW "\t \\_ $messhost\n";
		}
	}
}

sub check_for_cpkeyclt_from_cli {
    my $histline;
    print_working("Checking /root/.bash_history for cpkeyclt \n");
    open( HIST, "/root/.bash_history" );
    my @HISTORY = <HIST>;
    close(HIST);
    my @cpkeycltINHist;
    my $histtime;
    foreach $histline (@HISTORY) {
        chomp($histline);
        if ( substr( $histline, 0, 1 ) eq "#" ) {
            $histtime = substr( $histline, 1 );
        }
        if ( $histline =~ m/cpkeyclt/ ) {
            push( @cpkeycltINHist,
                    "\t \\_ On "
                  . BOLD GREEN scalar localtime($histtime) . " - "
                  . $histline );
        }
    }
    my $cpkeyInHistLine;
    if (@cpkeycltINHist) {
        foreach $cpkeyInHistLine (@cpkeycltINHist) {
            chomp($cpkeyInHistLine);
            print "$cpkeyInHistLine\n";
        }
    }
    else {
        print BOLD CYAN "\t \\_ None\n";
    }
    print_working("Checking license_log for cpkeyclt (last 20): ");
    print "\n";
    my @Last20cpkeyclt =
qx[ grep 'License Update Request' /usr/local/cpanel/logs/license_log | tail -20 ];
    my $Last20;
    foreach $Last20 (@Last20cpkeyclt) {
        chomp($Last20);
        print YELLOW "\t \\_ " . $Last20 . "\n";
    }
}

sub check_routing {
    print_working("Displaying IP routing info (if any)\n");
    my @ROUTINGINFO = qx[ ip addr | grep 'inet ' 2> /dev/null ];
    my $routeline;
    foreach $routeline (@ROUTINGINFO) {
        chomp($routeline);
        my ($internal1) = ( split( /\s+/, $routeline ) )[2];
        my ($internal)  = ( split( /\//,  $internal1 ) )[0];
        if ( $internal eq "127.0.0.1" ) { next; }
        print BOLD MAGENTA ON_BLACK . "\t \\_ Internal: " . CYAN $internal;
        my $external =
qx[ wget -O - -q --tries=1 --timeout=2 --bind-address=$internal http://myip.cpanel.net/v1.0/ 2> /dev/null ];
        if ($external) {
            chomp($external);
            print BOLD MAGENTA ON_BLACK " / External: " . CYAN $external . "\n";
        }
        else {
            print RED " / No Reply!\n";
        }
    }
}

sub check_root_servers {
    print_working("Checking if this server can resolve ROOT servers:\n");
    my @ROOT      = qw( a b c d e f g h i j k l m );
    my $ROOT_HOST = ".root-servers.net";
    my $rootserver;
    foreach $rootserver (@ROOT) {
        $rootserver = $rootserver . $ROOT_HOST;
        my $GOOD = qx[ dig $rootserver +short 2> /dev/null ];
        if ($GOOD) {
            print_OK("\t \\_ $rootserver - OK!");
            print "\n";
        }
        else {
            print_warn("\t \\_ $rootserver - Failed!");
        }
    }
}

sub get_date {
    print_working("Checking Date/Time:\n");
    my ($servertime) = ( split( /\./, clock_gettime(CLOCK_REALTIME) ) );
    print BOLD GREEN ON_BLACK "\t \\_ Server Time: "
      . $servertime . " ("
      . scalar localtime($servertime) . ")\n";
    my ($utctime) = (
        split(
            /\./,
            qx[ /usr/bin/curl -s https://cpaneltech.ninja/cgi-bin/date.pl ]
        )
    );
    if ( $utctime eq "" ) {
        ($utctime) = (
            split(
                /\./,
                qx[ /usr/bin/curl -sk https://cpaneltech.ninja/cgi-bin/date.pl ]
            )
        );
    }
    if ( $utctime eq "" ) {
        $utctime = "Could Not Retrieve! - check network/firewall\n";
	    print BOLD GREEN ON_BLACK "\t \\_ Outside Location: "
      	. BOLD MAGENTA $utctime; 
    }
	else { 
	    print BOLD GREEN ON_BLACK "\t \\_ Outside Location: "
      	. $utctime . " ("
      	. scalar localtime($utctime) . ")\n";
    	my $timediff = $servertime - $utctime;
    	if ( $timediff != 0 ) {
        	if ( $timediff < -5 or $timediff > 5 ) {
            	print_warn(
                	"\t \\_ [WARN] - Date/Time is off my more than 5 seconds!");
        	}
        	else {
            	print_OK("\t \\_ [OK] - Date/Time is within 5 seconds!");
            	print "\n";
        	}
    	}
	}
}

sub check_auth_cpanel_resolution {
    print_working("Checking to see if auth.cpanel.net can resolve: ");
    my $AUTH_RESOLUTION = qx[ dig auth.cpanel.net +short 2>/dev/null ];
    chomp($AUTH_RESOLUTION);
    if ($AUTH_RESOLUTION) {
        print_OK("OK!");
        print "\n";
    }
    else {
        print_warn("Failed!");
    }
}

sub check_etc_mtab_file {
    print_working("Checking /etc/mtab file: ");
    my $filestatus = "";
    if ( -e ("/etc/mtab") ) {
        $filestatus = "Exists!";
    }
    else {
        $filestatus = "Missing!";
    }
    if ( -l ("/etc/mtab") ) {
        my $target = readlink("/etc/mtab");
        $filestatus .= ", is a symlink to: " . $target;
    }
    else {
        $filestatus .= ", is a regular file (not symlinked)";
        if ( -z ("/etc/mtab") ) {
            $filestatus .= ", is empty";
        }
        else {
            $filestatus .= ", is not empty";
        }
    }
    print_OK($filestatus);
    print "\n";
}

sub check_other_ports {
    print_working(
        "Checking firewall (if license ports can access auth.cpanel.net):\n");
    eval("use IO::Socket::PortState qw( check_ports )");
    my %port_hash = (
        tcp => {
            2089 => {},
            80   => {},
            110  => {},
            143  => {},
            25   => {},
            23   => {},
            993  => {},
            995  => {},
        }
    );
    my $timeout = 5;
    my $host    = 'auth.cpanel.net';
    chomp($host);
    my $host_hr = check_ports( $host, $timeout, \%port_hash );
    for my $port ( sort { $a <=> $b } keys %{ $host_hr->{tcp} } ) {
        my $yesno = $host_hr->{tcp}{$port}{open} ? GREEN "OK!" : RED "Failed!";
        chomp($yesno);
        print_OK( "\t \\_ " . $port . " - " . $yesno );
        print "\n";
    }
}

sub check_perms_on_cpanel_lisc_file {
    return if ( !-e "/usr/local/cpanel/cpanel.lisc" );
    print_working("Checking permissions on cpanel.lisc file: ");
    my $statmode = ( stat("/usr/local/cpanel/cpanel.lisc") )[2] & 07777;
    $statmode = sprintf "%lo", $statmode;
    if ( $statmode != 644 ) {
        print_warn( "Invalid - (" . $statmode . ") - Should be 0644" );
    }
    else {
        print_OK("OK!");
        print "\n";
    }
    get_age();
#    my @OutPut =
#qx[ cat /usr/local/cpanel/cpanel.lisc | sed -n '/License Version/,/crc32/p' ];
#    my $lineoutput;
#    foreach $lineoutput (@OutPut) {
#        chomp($lineoutput);
#        print BOLD YELLOW "\t \\_ " . $lineoutput . "\n";
#    }
}

sub is_file_immutable {
    my $file = $_[0];
    chomp($file);
    if ( !-e "$file" ) {
        print_warn("$file file is missing!");
        return;
    }
    print BOLD MAGENTA "\t \\_ $file: ";
    my $attr = `/usr/bin/lsattr $file`;
    if ( $attr =~ m/^\s*\S*[ai]/ ) {
        print_warn("is immutable!");
        print "\n";
        print_warn(
"*******************************************************************"
        );
        print_warn(
"************************* ESCALATE TO L3! *************************"
        );
        print_warn(
"*******************************************************************"
        );
    }
    else {
        print_OK("All Good!");
        print "\n";
    }
}

sub read_last_50_lines_of_license_log {
    print_working(
        "Displaying last 50 lines of /usr/local/cpanel/logs/license_log:\n");
    my $lineswanted = 50;
    my $filename    = "/usr/local/cpanel/logs/license_log";
    my ( $line, $filesize, $seekpos, $numread, @lines );
    open F, $filename or die "Can't read $filename: $!\n";
    $filesize = -s $filename;
    $seekpos  = 50 * $lineswanted;
    $numread  = 0;
    while ( $numread < $lineswanted ) {
        @lines   = ();
        $numread = 0;
        seek( F, $filesize - $seekpos, 0 );
        <F> if $seekpos < $filesize;
        while ( defined( $line = <F> ) ) {
            push @lines, $line;
            shift @lines if ++$numread > $lineswanted;
        }
        if ( $numread < $lineswanted ) {
            if ( $seekpos >= $filesize ) {
                die
"There aren't even $lineswanted lines in $filename - I got $numread\n";
            }
            $seekpos *= 2;
            $seekpos = $filesize if $seekpos >= $filesize;
        }
    }
    close F;
    print @lines;
}

sub is_ntpd_installed {

    # Probably need to check if the RPM is installed
    # rpm -qa | egrep 'ntp|ntpdate'
    print_working("Checking to see if ntp[d] is running: ");
    my $ntpfound = qx[ ps ax | grep ntp | grep -v grep 2> /dev/null ];
    if ($ntpfound) {
        print_OK("Yes");
        print "\n";
    }
    else {
        print_OK("No (Note that it is not required.)");
        print "\n";
    }
}

sub get_envtype {
    print_working("This server's environment (envtype) is: ");
    open( ENVTYPE, "/var/cpanel/envtype" );
    $envtype = <ENVTYPE>;
    close(ENVTYPE);
    if ($envtype) {
        print_OK($envtype);
        print "\n";
    }
    else {
        print_OK("Unknown");
        print "\n";
    }
}

sub get_mainip {
    print_working("Obtaining contents of /var/cpanel/mainip: ");
    open( MAINIP, "/var/cpanel/mainip" );
    $mainip = <MAINIP>;
    close(MAINIP);
    chomp($mainip);
    if ($mainip) {
        print_OK($mainip);

        # Check if $mainip is on this server
        my $isOnServer = qx[ ip addr show | grep $mainip ];
        chomp($isOnServer);
        if ( !($isOnServer) ) {
            print RED " [WARN] not on this server.";
        }
    }
    else {
        print_OK("Missing");
    }
    print "\n";
}

sub display_route {
    print_working("Displaying route -n:\n");
    print BOLD YELLOW "\t \\ \n";
    system_formatted("route -n");
    print "\n";
    print_working("Displaying ip route:\n");
    print BOLD YELLOW "\t \\ \n";
    system_formatted("ip route");
    print "\n";
    print_working("Displaying ip addr show:\n");
    print BOLD YELLOW "\t \\ \n";
    system_formatted("ip addr show");
    print "\n";
}

sub get_wwwacctconf_ip {
    my $conf = Cpanel::Config::LoadWwwAcctConf::loadwwwacctconf();
    print_working("Obtaining ADDR from /etc/wwwacct.conf file: ");
    my $wwwacctIP = $conf->{'ADDR'};
    print_OK($wwwacctIP);
    print "\n";
}

sub check_cron_log {
    my $ExistsInCron;
    print_working("Checking for cpkeyclt being run via cron: \n");
	if (-e("/etc/systemd/system/cron.service") and !-e("/var/log/cron")) { 
    	print BOLD GREEN ON_BLACK "\t \\_ journalctl cron check: ";
		$ExistsInCron =qx[ /usr/bin/journalctl | grep -i cron | grep cpkeyclt ];
    	chomp($ExistsInCron);
    	if ($ExistsInCron) {
        	print_warn("Found in cron log file");
    	}
    	else {
        	print_OK("Not found - Good!");
        	print "\n";
    	}
	} elsif (-e("/var/log/cron")) { 
    	print BOLD GREEN ON_BLACK "\t \\_ /var/log/cron: ";
    	$ExistsInCron = qx[ grep 'cpkeyclt' /var/log/cron ];
    	chomp($ExistsInCron);
    	if ($ExistsInCron) {
        	print_warn("Found in cron log file");
    	}
    	else {
        	print_OK("Not found - Good!");
        	print "\n";
    	}
	} else { 
		print_warn("\t \\_ No /var/log/cron file and systemd cron.service not configured!");
	}
    print BOLD GREEN ON_BLACK "\t \\_ /var/spool/cron/root file: ";
    $ExistsInCron = qx[ grep 'cpkeyclt' /var/spool/cron/root ];
    chomp($ExistsInCron);
    if ($ExistsInCron) {
        print_warn("Found in roots crontab file");
    }
    else {
        print_OK("Not found - Good!");
        print "\n";
    }
    print BOLD GREEN ON_BLACK "\t \\_ /etc/cron.d/ directory ";
    $ExistsInCron = qx[ grep -srl 'cpkeyclt' /etc/cron.d/* ];
    chomp($ExistsInCron);
    if ($ExistsInCron) {
        print_warn("Found in $ExistsInCron file");
    }
    else {
        print_OK("Not found - Good!");
        print "\n";
    }
    print BOLD GREEN ON_BLACK "\t \\_ /etc/cron.hourly/ directory ";
    $ExistsInCron = qx[ grep -srl 'cpkeyclt' /etc/cron.hourly/* ];
    chomp($ExistsInCron);
    if ($ExistsInCron) {
        print_warn("Found in $ExistsInCron file");
    }
    else {
        print_OK("Not found - Good!");
        print "\n";
    }
    print BOLD GREEN ON_BLACK "\t \\_ /etc/cron.daily/ directory ";
    $ExistsInCron = qx[ grep -srl 'cpkeyclt' /etc/cron.daily/* ];
    chomp($ExistsInCron);
    if ($ExistsInCron) {
        print_warn("Found in $ExistsInCron file");
    }
    else {
        print_OK("Not found - Good!");
        print "\n";
    }
    print BOLD GREEN ON_BLACK "\t \\_ /etc/cron.weekly/ directory ";
    $ExistsInCron = qx[ grep -srl 'cpkeyclt' /etc/cron.weekly/* ];
    chomp($ExistsInCron);
    if ($ExistsInCron) {
        print_warn("Found in $ExistsInCron file");
    }
    else {
        print_OK("Not found - Good!");
        print "\n";
    }
    print BOLD GREEN ON_BLACK "\t \\_ /etc/cron.monthly/ directory ";
    $ExistsInCron = qx[ grep -srl 'cpkeyclt' /etc/cron.monthly/* ];
    chomp($ExistsInCron);
    if ($ExistsInCron) {
        print_warn("Found in $ExistsInCron file");
    }
    else {
        print_OK("Not found - Good!");
        print "\n";
    }
}

sub check_for_cpnat {
    print_working("Checking for existence of cpnat file (1:1 NAT): ");
    if ( -e ("/var/cpanel/cpnat") ) {
        open( CPNAT, "/var/cpanel/cpnat" );
        my @CPNAT = <CPNAT>;
        close(CPNAT);
        my $cpnatline = "";
        print_OK("Found one - contents are:");
        print "\n";
        foreach $cpnatline (@CPNAT) {
            chomp($cpnatline);
            print BOLD YELLOW "\t \\_ " . CYAN $cpnatline . "\n";
        }
        print "\n";
    }
    else {
        print_OK("None");
        print "\n";
    }
}

sub run_rdate {
    return if ( $envtype eq "virtuozzo" );
    print_working("Checking if rdate completes without error: ");
    my $rdatesuccess = qx[ rdate -s rdate.cpanel.net ];
    if ($rdatesuccess) {
        print_warn("Error - $rdatesuccess");
    }
    else {
        print_OK("Success!");
        print "\n";
    }
}

sub check_iptables {
    print_working("Checking if cPanel IP's (208.74.x.x) are blocked: ");
    my $IPTABLES_CHK = qx[ iptables -L -n | grep '^208.74.' | grep DROP ];
    if ($IPTABLES_CHK) {
        print_warn("cPanel IP's may be blocked (IPTABLES)");
    }
    else {
        print_OK("Looks good!");
        print "\n";
    }
}

sub check_for_trial {
    print_working("Checking for trial license: ");
    if ( -e ("/var/cpanel/trial") ) {
        print RED "Trial License Detected!\n";
    }
    else {
        print BOLD GREEN "No Trial License Detected!\n";
    }
}

sub is_lisc_lockable {
    print_working("Checking if cpanel.lisc can be locked: ");
    if ( -e ("/usr/local/cpanel/cpanel.lisc") ) {
        my $Lockable =
qx[ /usr/bin/flock -w 5 /usr/local/cpanel/cpanel.lisc -c "echo SUCCESS" || echo "FAILED" ];
        chomp($Lockable);
        if ( $Lockable eq "SUCCESS" ) {
            print_OK("Success");
            print "\n";
        }
        else {
            print_warn("FAILED TO OBTAIN LOCK!");
        }
    }
}

sub get_cpsrvd_restarts {
    print_working("Displaying last 20 cpsrvd restarts: ");
    print "\n";
    my $cpsrvdrestline;
    my @CPSRVD_RESTARTS =
qx[ grep 'Restarting cpsrvd daemon process' /usr/local/cpanel/logs/error_log | tail -20 ];
    foreach $cpsrvdrestline (@CPSRVD_RESTARTS) {
        chomp($cpsrvdrestline);
        my ( $restartdate, $restarttime, $restartdst ) =
          ( split( /\s+/, $cpsrvdrestline ) )[ 0, 1, 2 ];
        print YELLOW "\t \\_ "
          . $restartdate . " "
          . $restarttime . " "
          . $restartdst . "\n";
    }
    print_working("Checking /root/.bash_history for restarts: \n");
    my $histline;
    open( HIST, "/root/.bash_history" );
    my @HISTORY = <HIST>;
    close(HIST);
    foreach $histline (@HISTORY) {
        chomp($histline);
        if (   $histline =~ m/cpanel.service/
            or $histline =~ m/scripts\/restartsrv_cpsrvd/
            or $histline =~ m/service cpanel restart/
            or $histline =~ m/etc\/init.d\/cpanel/ )
        {
            print YELLOW "\t \\_ Found: " . BOLD GREEN $histline . "\n"
              unless ( $histline =~ m/grep/ );
        }
    }
}

sub arping_check {
    my $nicdevice = $_[0];
	my $nicIPAddr = $_[1];
    return if ( $envtype eq "virtuozzo" );
    print_working(
"Checking $nicdevice for multiple devices responding to $nicIPAddr "
    );
    my $ARPINGCMD = "";
    $ARPINGCMD =
qx[ arping -D -I $nicdevice -c 2 $nicIPAddr | grep 'Received 0' ];
    chomp($ARPINGCMD);
    if ( $ARPINGCMD =~ m/Received 0/ ) {
        print_OK("Good! - None found");
        print "\n";
    }
    else {
        print_warn(
"\n\t \\_ $nicIPAddr may be listening on other devices! ($ARPINGCMD)"
        );
    }
}

sub check_for_multiple_defroute {
    my $nicdevice = $_[0];
    print_working("Checking $nicdevice for multiple DEFROUTE=yes lines: ");
    my $defroutecnt =
qx[ grep -c '^DEFROUTE=yes' /etc/sysconfig/network-scripts/ifcfg-$nicdevice ];
    if ( $defroutecnt > 1 ) {
        print_warn(
"\n\t \\_ Multiple DEFROUTE=yes lines found in /etc/sysconfig/network-scripts/ifcfg-$nicdevice"
        );
    }
    else {
        print_OK("Only 1 found - GOOD!");
        print "\n";
    }
}

sub run_check_valid_server_hostname {
    print_working("Checking For Valid Server Hostname: ");
    my $HostnameValid = Cpanel::Validate::Hostname::is_valid($HOSTNAME);
    if ($HostnameValid) {
        print_OK("OK\n");
    }
    else {
        print_warn("[WARN] - $HOSTNAME is not valid!");
    }
}

sub check_for_dhcp {
    my $nicdevice = $_[0];
    print_working("Checking Networking Configs For DHCP:\n");
    my $grep4dhcp =
      qx[ grep -i 'dhcp' /etc/sysconfig/network-scripts/ifcfg-$nicdevice ];
    my $Look4NM_dhclient = qx[ ps fuax | egrep 'NetworkManager|dhclient' | grep -v grep ];
    if ($grep4dhcp) {
        print_warn( "\t \\_ "
              . $nicdevice
              . " has DHCP config. May cause IP/Hostname to change automatically!"
        );
    }
    if ($Look4NM_dhclient) {
        print_warn(
"\t \\_ NetworkManager or dhclient running. May cause IP/Hostname to change automatically!"
        );
    }
    if ( !$grep4dhcp and !$Look4NM_dhclient ) {
        print BOLD CYAN "\t \\_ None Found\n";
    }
}

sub check_for_cloudcfg {
    print_working("Checking for /etc/cloud/cloud.cfg.d/");
    if ( !( -e ("/etc/cloud") ) ) {
        print " - None Found\n";
        return;
    }
    print BOLD GREEN " - Found!\n";
    if ( -e ("/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg") ) {
        print_OK("99-preserve-hostname.cfg is present");
        print "\n";
        return;
    }
    my $preserve_hostname =
      qx[ grep -srl 'preserve_hostname: true' /etc/cloud/* ];
    my $manageetchosts = qx[ grep -srl 'manage_etc_hosts: false' /etc/cloud/* ];
    if ($preserve_hostname) {
        print_OK("\t \\_ preserve_hostname true!");
        print "\n";
    }
    else {
        print_warn(
            "\t \\_ preserve_hostname not set! in /etc/cloud/cloud.cfg.d/");
    }
    if ($manageetchosts) {
        print_OK("\t \\_ manage_etc_hosts false!");
        print "\n";
    }
    else {
        print_warn(
            "\t \\_ manage_etc_hosts not set! in /etc/cloud/cloud.cfg.d/");
    }
}

sub check_for_solo {
	return if (!(-e "/usr/local/cpanel/cpanel.lisc"));
    print_working("Checking for solo license: ");
    my $isSolo = "No";
    my ($isSoloNum) = (
        split(
            /\s+/, qx[ grep -a 'maxusers' /usr/local/cpanel/cpanel.lisc ]
        )
    )[1];
    if ( $isSoloNum == 1 ) {
        $isSolo = "Yes";
    }
    print BOLD CYAN $isSolo;
    my $TotalAccts = qx[ wc -l /etc/trueuserdomains ];
    if ( $TotalAccts > 1 and $isSoloNum == 1 ) {
        print_warn(
            "\n\t \\_ SOLO LICENSE WITH MORE THAN 1 ACCOUNT DETECTED!!! [HAN SHOT FIRST!]");
    }
    else {
        print "\n";
    }
}

sub getVerifyJSON {
    print_working(
        "https://verify.cpanel.net JSON data for $EXTERNAL_IP_ADDRESS_80: \n");
    my $JSONVerifyPage =
qx[ curl -s "https://verify.cpanel.net/verifyFeed.cgi?json=1&ip=$EXTERNAL_IP_ADDRESS_80" | python -mjson.tool ];
    print $JSONVerifyPage;
}

sub getHist {
    open( HIST, "/root/.bash_history" );
    my @HISTORY = <HIST>;
    close(HIST);
    my $histline;
    my $histtime;
    foreach $histline (@HISTORY) {
        chomp($histline);
        if ( substr( $histline, 0, 1 ) eq "#" ) {
            $histtime = substr( $histline, 1 );
        }
        if ( $histline =~ m/ip route |cpanel\.lisc|cpsanitycheck.so|sectools|3jenan|secinstall|update_cpanelv2|ip route del blackhole|license.onlinelic.net|\.\/s\.sh|tsocks \/usr\/local\/cpanel\/cpkeyclt/)
        {
            print BOLD YELLOW "\t \\_ Found in /root/.bash_history: "
              . BOLD GREEN scalar localtime($histtime) . " - "
              . RED $histline . "\n"
              unless ( $histline =~ m/grep/ );
        }
    }
}

sub chk_etc_hosts { 
    open( HOSTS, "/etc/hosts" );
    my @HOSTS = <HOSTS>;
    close(HOSTS);
    my $hostline;
    foreach $hostline (@HOSTS) {
        chomp($hostline);
        if ( $hostline =~ m/auth.cpanel.net|auth2.cpanel.net|auth3.cpanel.net|dev.cpanel.net/)
        {
            print BOLD YELLOW "\t \\_ Found this in /etc/hosts: " . RED $hostline . " - Escalate to L3!\n";
        }
    }
}

sub url_encode {
    my $rv = shift;
    $rv =~ s/([^a-z\d\Q.-_~ \E])/sprintf("%%%2.2X", ord($1))/geix;
    $rv =~ tr/ /+/;
    return $rv;
}

sub getMAC {
    my $macaddr        = $_[0];
    my $macaddrencoded = url_encode($macaddr);
    my $MACchkURL      = "https://cpaneltech.ninja/cgi-bin/getvendor.cgi";
    my $result         = qx[ curl -s "$MACchkURL?$macaddr" ];
    chomp($result);
	$result =~ s/\s+$//;
    return $result;
}

sub get_last_reboots {
    print_working("Getting Last 20 reboots:\n");
	my @LastReboots = qx[ last | grep reboot ];
	my $cnt=0;
	my ($rebootline, $kernel, $mday, $mon, $day, $hhmm);
	foreach $rebootline(@LastReboots) { 
		chomp($rebootline);
		($kernel,$mday,$mon,$day,$hhmm)=(split(/\s+/,$rebootline))[3,4,5,6,7];
		print YELLOW "\t \\_ Reboot detected with kernel $kernel On: $mday $mon $day $hhmm\n";
		$cnt++;
		if ($cnt >= 20) { last; }
	}
}

sub check_resolvconf {
    print_working("Checking /etc/resolv.conf for anomalies:\n");
    my $grep4NM = qx[ grep 'Generated by NetworkManager' /etc/resolv.conf ];
    if ($grep4NM) {
        print_warn(
"\t\\_ /etc/resolv.conf was possibly Generated by NetworkManager - may cause resolution issues!"
        );
    }
    my $grep4invalidNS = qx[ grep 'nameserver 127.0.0.' /etc/resolv.conf ];
    if ($grep4invalidNS) {
        print_warn(
"\t\\_ /etc/resolv.conf has invalid nameserver value - may cause resolution issues!"
        );
    }
    if ( !$grep4NM and !$grep4invalidNS ) {
        print_OK("\t\\_ All Good!\n");
    }
}

sub check_for_centOS5 {
    my $sysinfo_config = '/var/cpanel/sysinfo.config';
    return if !-f $sysinfo_config;
    my $rpm_dist_ver;
    open my $fh, '<', $sysinfo_config or return;
    while (<$fh>) {
        if (/^rpm_dist_ver=(\d+)$/) {
            $rpm_dist_ver = $1;
            last;
        }
    }
    close $fh or return;
    return if !$rpm_dist_ver;
    return if ( $rpm_dist_ver > 5 );
    print_warn("Sorry, this cannot run on your version of OS!");
    print "</c>\n";
    exit;
}

sub check_hostsfile {
    print_working("Checking /etc/hosts for $HOSTNAME\n");
    my $hostsfile = qx[ grep $HOSTNAME /etc/hosts ];
    if ( substr( $hostsfile, 0, 1 ) eq "#" ) {
        print_warn(
            "\t\\_ $HOSTNAME appears to be commented out in /etc/hosts!");
        return;
    }
    if ($hostsfile) {
        print BOLD GREEN "$HOSTNAME found in /etc/hosts\n";
        print BOLD CYAN "\t\\_ $hostsfile";
    }
    else {
        print_warn("\t\\_ $HOSTNAME not found in /etc/hosts");
    }
}

sub get_age {
    my $age;
    $age = ( stat("/usr/local/cpanel/cpanel.lisc") )[9];
    my $TimeDiff = $timenow - $age;
    if ( $TimeDiff > 604800 ) {
        print_warn("cpanel.lisc file is older than 7 days!");
    }
}

sub getExpCnt { 
	print_working("Obtaining total expired messages from license_log: ");
	my $ExpCnt = qx[ grep -c '^The license is expired' /usr/local/cpanel/logs/license_log ];
	print BOLD CYAN $ExpCnt;
}

sub getLockedCnt { 
	print_working("Obtaining total license locked messages from license_log: ");
	my $LockedCnt = qx[ grep -c '^The license has been activated too many times' /usr/local/cpanel/logs/license_log ];
	print BOLD CYAN $LockedCnt;
}

sub getFailCnt { 
	print_working("Obtaining total license update failed messages from license_log: ");
	my $FailCnt = qx[ grep -c 'License update failed' /usr/local/cpanel/logs/license_log ];
	print BOLD CYAN $FailCnt;
}

sub getSuccessCnt { 
	print_working("Obtaining total license update succeeded messages from license_log: ");
	my $SuccessCnt = qx[ grep -c 'License update succeeded' /usr/local/cpanel/logs/license_log ];
	print BOLD CYAN $SuccessCnt;
}

sub chkCreds { 
	return if(-e("/var/cpanel/licenseid_credentials.json"));
	print_warn("licenseid_credentials.json file missing - is port 2083 inbound open?");
}

sub get_logStats { 
	my $expireCnt=qx[ grep -c '^The license is expired' /usr/local/cpanel/logs/license_log ];
	my $activeCnt=qx[ grep -c '^The license has been activated too many times' /usr/local/cpanel/logs/license_log ];
	my $failureCnt=qx[ grep -c 'License update failed' /usr/local/cpanel/logs/license_log ];
	my $successCnt=qx[ grep -c 'License update succeeded' /usr/local/cpanel/logs/license_log ];
	my $TotTWRestarts=qx[ grep -c 'Restarting cpsrvd' /var/log/chkservd.log ];
	chomp($expireCnt);
	chomp($activeCnt);
	chomp($failureCnt);
	chomp($successCnt);
	chomp($TotTWRestarts);
	print_working("Obtaining stats from license_log file:\n");
	print BOLD CYAN "\t\\_ Total number of times license has expired: " . MAGENTA $expireCnt . "\n";
	print BOLD CYAN "\t\\_ Total number of times license has been activated too many times: " . MAGENTA $activeCnt . "\n";
	print BOLD CYAN "\t\\_ Total number of times license update has failed: " . MAGENTA $failureCnt . "\n";
	print BOLD CYAN "\t\\_ Total number of times license update has succeeded: " . MAGENTA $successCnt . "\n";
	print BOLD CYAN "\t\\_ Total number of times chkservd has restarted cpsrvd: " . MAGENTA $TotTWRestarts . "\n";
	return;
}

sub chk_for_lisclock { 
	return if(!(-e("/usr/local/cpanel/lisc.lock")));
	print_warn("lisc.lock file present!");
}

sub shenanigans { 
    print_working("Checking for strange configurations \n");
	getHist();
	chk_etc_hosts();
	chk_fwdip();
	chk_etc_ips();
	chk_cgls();
}

sub chk_fwdip { 
	return if (!(-e("/var/cpanel/domainfwdip")));
	my $fwdip;
	my @FWDIP;
	open(FWDIP,"/var/cpanel/domainfwdip");
	@FWDIP=<FWDIP>;
	close(FWDIP);
	foreach $fwdip(@FWDIP) { 
		chomp($fwdip);
		if ($fwdip =~ m/208.74./) { 
			print RED "\t\\_ Found $fwdip in /var/cpanel/domainfwdip file - Escalate to L3!\n";
		}
	}
}

sub get_ipinfo {
	my $ipinfoIP=$_[0];
	my $ipinfoline;
	print_working("Getting ipinfo for $ipinfoIP\n");
	my @IPINFO=qx[ curl -s ipinfo.io/$ipinfoIP ];
	foreach $ipinfoline(@IPINFO) { 
		chomp($ipinfoline);
		if ($ipinfoline =~ m/{|}/) { 
			next;
		}
		$ipinfoline =~ s/\"//g;
		$ipinfoline =~ s/,$//g;
		print BOLD CYAN "\t\\_ $ipinfoline\n";
	}	
}

sub get_cpanel_license_file_info_href {
    my %license;
    if ( open my $license_fh, '<', $CPANEL_LICENSE_FILE ) {
        my @license_text;
        while (<$license_fh>) {
            last if m{ \A -----BEGIN }xms;
            next unless m{ \A \p{IsPrint}+ \Z }xms;
            chomp;
            push @license_text, $_;
        }
        close $license_fh;
        %license = map { ( split( /:\s+/, $_, 2 ) )[ 0, 1 ] } @license_text;
    }
    return \%license;
}
sub license_file_is_cloudlinux {
    my $href = get_cpanel_license_file_info_href();
    return "None" if not exists $href->{products};
    return "Yes" if grep { /cloudlinux/ } $href->{products};
    return "No";
}
sub license_file_is_cpanel {
    my $href = get_cpanel_license_file_info_href();
    return "None" if not exists $href->{products};
    return "Yes" if grep { /cpanel/ } $href->{products};
    return "No";
}
sub license_file_is_dnsonly {
    my $href = get_cpanel_license_file_info_href();
    return "None" if not exists $href->{products};
    return "Yes" if grep { /dnsonly/ } $href->{products};
    return "No";
}
sub license_file_is_solo {
    my $href = get_cpanel_license_file_info_href();
    return "None" if not exists $href->{products} or not exists $href->{maxusers};
    return "Yes" if ( grep { /cpanel/ } $href->{products} and $href->{maxusers} == 1 );
    return "No";
}
sub license_file_ip {
    my $href = get_cpanel_license_file_info_href();
    return $href->{client};
}
sub license_file_support_expire {
    my $href = get_cpanel_license_file_info_href();
    return $href->{support_expire_time};
}
sub license_file_updates_expire {
    my $href = get_cpanel_license_file_info_href();
    return $href->{updates_expire_time};
}
sub license_file_expire {
    my $href = get_cpanel_license_file_info_href();
    return $href->{license_expire_time};
}
sub check_for_accountinglog {
    print_working("Checking accounting.log file for first created account\n");
	if (-e("/var/cpanel/accounting.log")) { 
		my $FirstAcct=qx[ grep ':CREATE:' /var/cpanel/accounting.log | head -1 ];
		my $delim="CREATE";
		my $FirstAcctEnd = index($FirstAcct,$delim,0);
		my $FirstAcctDate = substr($FirstAcct,0,$FirstAcctEnd-0);
		chop($FirstAcctDate);
		print BOLD CYAN "\t\\_ First account created on: " . YELLOW $FirstAcctDate . "\n";
	}
	else { 
		print BOLD CYAN "\t\\_ None - Possible new install\n";
	}
}
sub chk_etc_ips {
	my $ourIPinetcips=qx[ grep '208.74.' /etc/ips ];
	if ($ourIPinetcips) { 
		print BOLD YELLOW "\t \\_ Found cPanel IP's within /etc/ips file - Escalate to L3!\n";
	}
}
sub chk_cgls {
	my $dir="/usr/local/cgls";
	if (-e $dir and -d $dir) { 
		print RED "\t \\_ Found CGLS - Escalate to L3!\n";
	}
}
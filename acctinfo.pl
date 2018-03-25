#!/usr/local/cpanel/3rdparty/bin/perl
# SCRIPT: acctinfo                                                                    #
# PURPOSE: Get as much information for a username or domain entered at command line   #
# as possible.                                                                        #
# AUTHOR: Peter Elsner <peter.elsner@cpanel.net>                                      #
#######################################################################################

BEGIN {
    unshift @INC, '/usr/local/cpanel';
    unshift @INC, '/usr/local/cpanel/scripts';
    unshift @INC, '/usr/local/cpanel/bin';
}

use strict;
my $VERSION = "2.4.90";

our $sslsyscertdir;
our $sslsubject;
our $startdate;
our $expiredate;
our $isSelfSigned;
our $CPVersion = `cat /usr/local/cpanel/version`;
our $result;
chomp($CPVersion);

use Getopt::Long;
use Cpanel::MysqlUtils;
use Term::ANSIColor qw(:constants);
use Cpanel::Sys::Hostname           ();
use Cpanel::Config::LoadCpUserFile  ();
use Cpanel::Config::Users           ();
use Cpanel::Config::LoadWwwAcctConf ();
use Cpanel::Config::LoadCpConf      ();
use Cpanel::ResellerFunctions       ();
use Cpanel::Usage                   ();
use Time::Piece;
use Time::Seconds;
use String::Random;
use Text::Tabs;
$tabstop = 4;
use Net::DNS;
use Socket;
use DBI;
use integer;

# Just found out that Date::Manip is only available in 11.58+
# (in 11.56 and lower, it's not installed).
my $noDateManip = 0;
eval("use Date::Manip");
if ($@) {
    $noDateManip = 1;
}

$Term::ANSIColor::AUTORESET = 1;

my $all           = undef;
my $listdbs       = undef;
my $listssls      = undef;
my $listsubs      = undef;
my $listaddons    = undef;
my $listparked    = undef;
my $listaliased   = undef;
my $reselleraccts = undef;
my $resellerperms = undef;
my $resellerprivs = undef;
my $clearscreen   = undef;
my $helpME        = undef;
my $SearchFor     = undef;
my $useDig        = undef;
my $cruft         = undef;
my $mail          = undef;
my $scan          = undef;
my $nocodeblock   = undef;
my $skipquota     = 0;
my $skipfind      = 0;
our $spincounter;
our $CAADOMAIN;

GetOptions(
    'listdbs'       => \$listdbs,
    'listssls'      => \$listssls,
    'listsubs'      => \$listsubs,
    'listaddons'    => \$listaddons,
    'listaliased'   => \$listaliased,
    'listparked'    => \$listaliased,
    'reselleraccts' => \$reselleraccts,
    'resellerperms' => \$resellerperms,
    'resellerprivs' => \$resellerperms,
    'all'           => \$all,
    'help'          => \$helpME,
    'useDig'        => \$useDig,
    'cruft'         => \$cruft,
    'mail'          => \$mail,
    'scan'          => \$scan,
    'skipquota'     => \$skipquota,
    'skipfind'      => \$skipfind,
    'q'             => \$clearscreen,
    'nocode'        => \$nocodeblock,
);

if ($skipquota) {
    $skipquota = 1;
}
if ($skipfind) {
    $skipfind = 1;
}

if ($clearscreen) {
    system("clear");
}
print "<c>\n" unless ($nocodeblock);
print BOLD BLUE "acctinfo - Version: " . YELLOW $VERSION . "\n";
if ($helpME) {
    Usage();
}

my $conf      = Cpanel::Config::LoadWwwAcctConf::loadwwwacctconf();
my $HOMEDIR   = $conf->{'HOMEDIR'};
my $HOMEMATCH = $conf->{'HOMEMATCH'};
my $SERVER_IP = $conf->{'ADDR'};
my $cpconf    = Cpanel::Config::LoadCpConf::loadcpconf();
my $DBPrefix  = $cpconf->{'database_prefix'};

my ( $os_release, $os_ises ) = get_release_version();

my $IS_USERNAME = 1;

my $QUERY = @ARGV[0];
chomp($QUERY);
if ( $QUERY eq "" ) {
    Usage();
}
$QUERY = lc($QUERY);
if ( index( $QUERY, '.' ) != -1 ) {
    $IS_USERNAME = 0;
}

my $HOSTNAME   = Cpanel::Sys::Hostname::gethostname();
my $MAINDOMAIN = "";
my $username   = "";

if ($IS_USERNAME) {
    $MAINDOMAIN = FindMainDomain($QUERY);
    $username   = $QUERY;
}
else {
    $username   = FindUser($QUERY);
    $MAINDOMAIN = FindMainDomain($username);
}
chomp($MAINDOMAIN);
chomp($username);
if ( !($MAINDOMAIN) ) {
    $username   = FindUser($QUERY);
    $MAINDOMAIN = FindMainDomain($username);
}

# Check for reserved username
my $UserIsReserved;
if ($username) {
    $UserIsReserved = isUserReserved($username);
}
else {
    $UserIsReserved = isUserReserved($QUERY);
}
if ($UserIsReserved) {
    print RED "[WARNING] - " . WHITE " Reserved username detected!\n";
    if ($username) {
        my $RandomString  = new String::Random;
        my $SuggestedUser = $RandomString->randpattern("cccccc");
        print YELLOW
"You can use the following API call to change $username to for example: $username$SuggestedUser\n";
        print BOLD MAGENTA
"/usr/sbin/whmapi1 modifyacct user=$username newuser=$username$SuggestedUser\n";
    }
}

# If both variables are still empty, neither the username nor the domain name were found!
if ( $MAINDOMAIN eq "" and $username eq "" ) {
    if ($cruft) {
        cruft_check();
    }
    print
"Error - $QUERY not found on $HOSTNAME (or missing from /etc/userdomains file)\n";
    print "Try using the --cruft switch (acctinfo $QUERY --cruft)\n";
    print "</c>\n" unless ($nocodeblock);
    exit;
}

if ($scan) {
    scan();
    exit;
}

if ( $username eq "nobody" ) {
    print RED "[WARN] - "
      . YELLOW $QUERY
      . " has an owner of "
      . WHITE
      . "\"nobody\""
      . YELLOW " in /etc/userdomains!\n";
    exit;
}

# Load /var/cpanel/users/$username into config hash variable
my $user_conf                 = Cpanel::Config::LoadCpUserFile::load($username);
my $DOMAIN                    = $QUERY;
my $IS_PARKED                 = "";
my $IS_ADDON                  = "";
my $IS_SUB                    = "";
my @SUBDOMAINS                = "";
my @ADDONDOMAINS              = "";
my @PARKEDDOMAINS             = "";
my $ACCT                      = "";
my $MAILBOX_FORMAT            = "";
my $SUSPEND_TIME              = "";
my $MAXPOP                    = 0;
my $MAX_EMAIL_PER_HOUR        = 0;
my $MAX_DEFER_FAIL_PERCENTAGE = 0;
open( USERDATAFILE, "/etc/userdatadomains" );
my @USERDATADOMAINS = <USERDATAFILE>;
close(USERDATAFILE);

# Get all sub domains (if any)
foreach $ACCT (@USERDATADOMAINS) {
    chomp($ACCT);
    if ( $ACCT =~ m/ $username=/ ) {
        if ( $ACCT =~ m/==sub==/ ) {
            my ($sub_domain) = ( split( /\s+/, $ACCT ) )[0];
            chop($sub_domain);
            push( @SUBDOMAINS, $sub_domain );
            if ( $sub_domain eq $DOMAIN ) {

                # Get documentroot for $DOMAIN from /etc/userdatadomains
                my ($docroot) =
                  ( split( /==/, qx[ grep $sub_domain /etc/userdatadomains ] ) )
                  [4];
                $IS_SUB =
                    expand("$DOMAIN is a sub domain of $MAINDOMAIN \n\t\\_ ")
                  . YELLOW
                  . "(DocumentRoot: "
                  . WHITE $docroot . ")\n";
            }
        }
    }
}

# Get all addon domains (if any)
foreach $ACCT (@USERDATADOMAINS) {
    chomp($ACCT);
    if ( $ACCT =~ m/ $username=/ ) {
        if ( $ACCT =~ m/==addon==/ ) {
            my ($addon_domain) = ( split( /\s+/, $ACCT ) )[0];
            chop($addon_domain);
            push( @ADDONDOMAINS, $addon_domain );
            if ( $addon_domain eq $DOMAIN ) {

                # Get documentroot for $DOMAIN from /etc/userdatadomains
                my ($docroot) = (
                    split(
                        /==/, qx[ grep $addon_domain /etc/userdatadomains ]
                    )
                )[4];
                $IS_ADDON =
                    expand("$DOMAIN is an addon domain of $MAINDOMAIN \n\t\\_ ")
                  . YELLOW
                  . "(DocumentRoot: "
                  . WHITE $docroot . ")\n";
            }
        }
    }
}

# Get all aliased domains (if any)
foreach $ACCT (@USERDATADOMAINS) {
    chomp($ACCT);
    if ( $ACCT =~ m/ $username=/ ) {
        if ( $ACCT =~ m/==parked==/ ) {
            my ($parked_domain) = ( split( /\s+/, $ACCT ) )[0];
            chop($parked_domain);
            push( @PARKEDDOMAINS, $parked_domain );
            if ( $parked_domain eq $DOMAIN ) {

                # Get documentroot for $DOMAIN from /etc/userdatadomains
                my ($docroot) = (
                    split(
                        /==/, qx[ grep $parked_domain /etc/userdatadomains ]
                    )
                )[4];
                $IS_PARKED = expand(
"$DOMAIN is an alias (parked) domain of $MAINDOMAIN \n\t\\_ "
                  )
                  . YELLOW
                  . "(DocumentRoot: "
                  . WHITE $docroot . ")\n";
            }
        }
    }
}

shift @SUBDOMAINS;
shift @ADDONDOMAINS;
shift @PARKEDDOMAINS;
my $subcnt   = @SUBDOMAINS;
my $addoncnt = @ADDONDOMAINS;
my $parkcnt  = @PARKEDDOMAINS;

if ($cruft) {
    cruft_check();
}

# We already have the $user_conf hash variable.
my $PACKAGE       = $user_conf->{'PLAN'};
my $THEME         = $user_conf->{'RS'};
my $IPADDR        = $user_conf->{'IP'};
my $BACKUPENABLED = $user_conf->{'BACKUP'};
my $LEGACYBACKUP  = $user_conf->{'LEGACY_BACKUP'};
my $BWLIMIT       = $user_conf->{'BWLIMIT'};
my $MAXADDON      = $user_conf->{'MAXADDON'};
my $MAXPARK       = $user_conf->{'MAXPARK'};
my $MAXSUB        = $user_conf->{'MAXSUB'};
my $MAXFTP        = $user_conf->{'MAXFTP'};
my $MAXSQL        = $user_conf->{'MAXSQL'};
my $MAXLST        = $user_conf->{'MAXLST'};
my $SUSPEND_TIME  = $user_conf->{'SUSPENDTIME'};
my $FEATURELIST   = $user_conf->{'FEATURELIST'};
my $STARTDATE     = scalar localtime( $user_conf->{'STARTDATE'} );
my @ResolvedIP;
my $ResolvedIP;

if ( $BWLIMIT ne "unlimited" ) {
    $BWLIMIT = ( $BWLIMIT / 1024 ) / 1024;
}

my $HAS_AUTOSSL =
qx[ whmapi1 verify_user_has_feature user=$username feature=autossl | grep 'has_feature: 1' ];

$HAS_AUTOSSL = ($HAS_AUTOSSL) ? "Yes" : "No";
my $HAS_AUTOSSL_TEXT;

# Check disabled feature list to see if autossl=0 exists
my $AutoSSL_Disabled = qx[ grep 'autossl=0' /var/cpanel/features/disabled ];
if ($AutoSSL_Disabled) {
    $HAS_AUTOSSL_TEXT = "(AutoSSL disabled in feature list)";
}

# Check $FEATURELIST feature list to see if autossl=0 exists
my $AutoSSL_Disabled;
if ( !( -e ("/var/cpanel/features/$FEATURELIST") ) ) {
    $AutoSSL_Disabled = "$FEATURELIST not found in /var/cpanel/features!";
    $HAS_AUTOSSL_TEXT = RED "[WARN] - Missing from /var/cpanel/features/";
}
else {
    $AutoSSL_Disabled =
      qx[ grep 'autossl=0' /var/cpanel/features/$FEATURELIST ];
    if ($AutoSSL_Disabled) {
        $HAS_AUTOSSL_TEXT = "(AutoSSL disabled in $FEATURELIST)";
    }
}
if ( $HAS_AUTOSSL_TEXT eq "" ) {
    $HAS_AUTOSSL_TEXT = "(AutoSSL enabled in \"$FEATURELIST\" feature list)";
}

$BACKUPENABLED = ($BACKUPENABLED) ? "Yes" : "No";
$LEGACYBACKUP  = ($LEGACYBACKUP)  ? "Yes" : "No";
if ($IS_USERNAME) {

 # Resolve the ip address of $MAINDOMAIN to see if it is pointing somewhere else
    if ($useDig) {
        @ResolvedIP =
          qx[ dig +tries=2 +time=5 \@208.67.220.220 $MAINDOMAIN A +short ];
    }
    else {
        @ResolvedIP = getArecords($MAINDOMAIN);
    }
}
else {
    # a domain name was entered so we should resolve the IP of that instead.
    if ($useDig) {
        @ResolvedIP =
          qx[ dig +tries=2 +time=5 \@208.67.222.222 $DOMAIN A +short ];
    }
    else {
        @ResolvedIP = getArecords($DOMAIN);
    }
}
my $IPTYPE = "";
if ( $IPADDR eq $SERVER_IP ) {
    $IPTYPE = "shared";
}
else {
    $IPTYPE = "dedicated";
}
my $REAL_OWNER = $user_conf->{'OWNER'};
my $RO_TEXT    = "";
if ( $REAL_OWNER ne $username and $REAL_OWNER ne "root" ) {
    $RO_TEXT = " (Which is under the reseller: $REAL_OWNER)";
}

# Check if main domain (username) is a reseller.
my @ACCTSOWNEDBYRESELLER = undef;
my @SORTEDRESELLERACCTS  = undef;
my @LISTOFACCTS          = undef;
my $Is_Reseller          = 0;
my $ResellerAcctsCnt     = 0;
my $ResellerDomain       = "";
my $vcu_account          = "";
my $ResellersAcct        = "";
my $RESELLER             = "";
my $FOUND                = "";
my $ResellerSharedIP     = "None";
my @ResellerIPS          = undef;
my $ResellerIP           = "None";
my $ResellerIPS          = "None";
my @ALL_RESELLERS        = Cpanel::ResellerFunctions::getresellerslist();
unshift @ALL_RESELLERS, 'root';

foreach $RESELLER (@ALL_RESELLERS) {
    chomp($RESELLER);
    if ( $RESELLER eq $username ) {
        $Is_Reseller = 1;

  # Grab resellers shared IP (if configured) from /var/cpanel/mainips/$RESELLER.
        if ( -e ("/var/cpanel/mainips/$RESELLER") ) {
            $ResellerSharedIP = qx[ cat /var/cpanel/mainips/$RESELLER ];
            chomp($ResellerSharedIP);
        }
        if ( -e ("/var/cpanel/dips/$RESELLER") ) {
            open( RESELLERIPS, "/var/cpanel/dips/$RESELLER" );
            @ResellerIPS = <RESELLERIPS>;
            close(RESELLERIPS);
        }

        # Read all accounts in /var/cpanel/users into array
        opendir( ACCTS, "/var/cpanel/users" );
        my @LISTOFACCTS = readdir(ACCTS);
        closedir(ACCTS);
        foreach $vcu_account (@LISTOFACCTS) {
            chomp($vcu_account);
            if (   $vcu_account =~ m/HASH/
                or $vcu_account eq "."
                or $vcu_account eq ".." )
            {
                next;
            }
            $FOUND = "";
            $FOUND =
              qx[ grep 'OWNER=$username' /var/cpanel/users/$vcu_account ];
            if ($FOUND) {
                $ResellersAcct =
                  qx[ grep 'DNS=' /var/cpanel/users/$vcu_account ];
                $ResellerDomain = substr( $ResellersAcct, 4 );
                chomp($ResellerDomain);
                push( @ACCTSOWNEDBYRESELLER, "$ResellerDomain ($vcu_account)" );
            }
        }
        $ResellerAcctsCnt = @ACCTSOWNEDBYRESELLER;
        $ResellerAcctsCnt--;
        last;
    }
}

my $TOTAL_DOMAINS = qx[ cat /etc/trueuserdomains | wc -l ];
chomp($TOTAL_DOMAINS);
print WHITE "There are "
  . YELLOW $TOTAL_DOMAINS
  . WHITE " total accounts on ("
  . GREEN ON_BLACK $HOSTNAME
  . WHITE ").\n";
if ($IS_USERNAME) {
    print "\n";
}
else {
    print GREEN ON_BLACK "\nThe user name for "
      . BLUE $DOMAIN
      . GREEN ON_BLACK " is: "
      . YELLOW $username . "\n";
}

# Get home directory from /etc/passwd
my @PASSWDS = undef;
our $RealHome    = "";
our $SSLProvider = getSSLProvider();
our $passline    = "";
my $RealShell = "";
my $UID       = "";
my $GID       = "";

open( PASSWD, "/etc/passwd" );
@PASSWDS = <PASSWD>;
close(PASSWD);

foreach $passline (@PASSWDS) {
    chomp($passline);
    if ( $passline =~ m/\b$username\b/ ) {
        ($UID)       = ( split( /:/, $passline ) )[2];
        ($GID)       = ( split( /:/, $passline ) )[3];
        ($RealHome)  = ( split( /:/, $passline ) )[5];
        ($RealShell) = ( split( /:/, $passline ) )[6];
        last;
    }
}

# Check for missing hash in /etc/shadow
my ($PWHash) = ( split( /:/, qx[ grep $username /etc/shadow ] ) )[1];
if ( $PWHash eq "" ) {
    print RED "[WARN] * $username is missing password hash in /etc/shadow\n";
}

# Get IP address from .lastlogin file (if it exists)
my $LastLoginIP =
qx[ uapi --user=$username LastLogin get_last_or_current_logged_in_ip | grep 'data:' | grep -v 'metadata' ];
chomp($LastLoginIP);
$LastLoginIP = substr( $LastLoginIP, 8 );

print GREEN ON_BLACK "The main domain is "
  . YELLOW $MAINDOMAIN
  . GREEN ON_BLACK $RO_TEXT . "\n";

if ( $MAINDOMAIN eq $HOSTNAME ) {
    print RED "[WARN] - $MAINDOMAIN is the same as hostname $HOSTNAME!\n";
}
if ( $QUERY eq $HOSTNAME ) {
    print RED "[WARN] - $QUERY is the same as hostname $HOSTNAME!\n";
}

# Get docroot for MAINDOMAIN too.
my ($maindocroot) =
  ( split( /==/, qx[ grep '^$MAINDOMAIN' /etc/userdatadomains ] ) )[4];
print expand(
    "\t\\_ " . YELLOW . "(DocumentRoot: " . WHITE $maindocroot . ")\n" );

print WHITE "Real Home Directory (/etc/passwd): " . CYAN $RealHome ;
print "\n";
checkperms();
print "\n";

# Check if user is in demo mode
my $InDemo = qx[ grep $username /etc/demousers /etc/demodomains];
if ($InDemo) {
    print RED "[WARN] - $username is in demo mode!\n";
}

# Check if bandwidth limit exceeded
if (   -e ("/var/cpanel/bwlimited/$username")
    or -e ("/var/cpanel/bwlimited/$MAINDOMAIN")
    or -e ("/var/cpanel/bwlimited/$QUERY") )
{
    print RED
"[WARN] - $MAINDOMAIN ($username) may have exceeded their bandwidth limit!\n";
    my ($bwused) =
qx[ uapi --user=$username StatsBar get_stats display=bandwidthusage | grep 'count:' | grep -v '_count' ];
    chomp($bwused);
    my ($bwmax) =
qx[ uapi --user=$username StatsBar get_stats display=bandwidthusage | grep 'max:' | grep -v '_max' ];
    chomp($bwmax);
    $bwused =~ s/count://g;
    $bwmax =~ s/max://g;
    $bwused = alltrim($bwused);
    $bwmax  = alltrim($bwmax);
    print expand("\t \\_ $bwused / $bwmax\n");
}
if ($Is_Reseller) {
    print GREEN ON_BLACK "This account is also a reseller!\n";
    if ($ResellerSharedIP) {
        print GREEN "Reseller's Shared IP: " . WHITE $ResellerSharedIP . "\n";
    }
    if (@ResellerIPS) {
        print GREEN "Reseller's IP Delegation\n";
        foreach $ResellerIP (@ResellerIPS) {
            chomp($ResellerIP);
            if ( $ResellerIP ne "" ) {
                print expand( YELLOW "\t \\_ $ResellerIP\n" );
            }
            else {
                print expand( YELLOW "\t \\_ Open Delegation " )
                  . CYAN
                  . "(any IP on this server can be used by "
                  . WHITE $username
                  . CYAN . ")\n";
            }
        }
    }
    else {
        print GREEN "Reseller's IP Delegation: ";
        print YELLOW "Open Delegation "
          . CYAN
          . "(any IP on this server can be used by "
          . WHITE $username
          . CYAN . ")\n";
    }
}
print GREEN "$IS_PARKED\n" unless ( $IS_PARKED eq "" );
print GREEN "$IS_ADDON\n"  unless ( $IS_ADDON eq "" );
print GREEN "$IS_SUB\n"    unless ( $IS_SUB eq "" );
print WHITE "Shell: " . CYAN $RealShell . "\n";
ChkForIntegration();

# check if user is in /etc/ftpusers
my $ftpblock = "";
if ( -e ("/etc/ftpusers") ) {
    $ftpblock = qx[ grep $username /etc/ftpusers ];
    if ($ftpblock) {
        print RED
"[WARN] - $username found in /etc/ftpusers file (FTP authentication will fail!\n";
    }
}
print WHITE "UID/GID: " . CYAN $UID . "/" . $GID;
my $UID_MIN = qx[ grep 'UID_MIN' /etc/login.defs ];
my $GID_MIN = qx[ grep 'GID_MIN' /etc/login.defs ];
($UID_MIN) = ( split( /\s+/, $UID_MIN ) )[1];
($GID_MIN) = ( split( /\s+/, $GID_MIN ) )[1];
$UID_MIN = alltrim($UID_MIN);
$GID_MIN = alltrim($GID_MIN);

if ( $UID < $UID_MIN or $GID < $GID_MIN ) {
    print RED " - [WARN] - UID/GID is less than $UID_MIN/$GID_MIN\n";
}
else {
    print "\n";
}

# get quota info using whmapi1
my $quotaused =
  alltrim(qx[ whmapi1 accountsummary user=$username | grep 'diskused:' ]);
($quotaused) = ( split( /\s+/, $quotaused ) )[1];
my $maxquota =
  alltrim(qx[ whmapi1 accountsummary user=$username | grep 'disklimit' ]);
($maxquota) = ( split( /\s+/, $maxquota ) )[1];
print "Disk Quota: $quotaused used of $maxquota allowed\n";

# Check if account is over quota, warn if so, unless --skipquota is passed.
# -s human-readable, -l local only (ignore NFS), -q quiet
# check if the account is over quota (slq does this, if nothing returned, it's not over quota.
if ( $skipquota == 0 ) {
    open( QUOTACHK, "/usr/bin/quota -slq $username 2> /dev/null |" );
    my @quotachk = <QUOTACHK>;
    close(QUOTACHK);
    my $BlockLimitReached;
    my $quotaused;
    my $quotaallowed;
    foreach $BlockLimitReached (@quotachk) {
        chomp($BlockLimitReached);
        if ( $BlockLimitReached =~ m/Block limit reached on / ) {
            print RED "[WARN] - $username is over quota ";
            my ($quotadev) = ( split( /\s+/, $BlockLimitReached ) )[5];
            my $quotaHR1 = qx[ grep $quotadev /etc/mtab ];
            my ($quotaHR) = ( split( /\s+/, $quotaHR1 ) )[1];
            ( $quotaused, $quotaallowed ) = (
                split(
                    /\s+/,
qx[ /usr/bin/quota -sl $username | egrep -v 'Filesystem|quotas' | tail -1 ]
                )
            )[ 2, 3 ];
            print
"($quotadev [$quotaHR] is over quota [$quotaused/$quotaallowed])\n";
        }
    }
}

if ( !( -e ("/var/cpanel/features/$FEATURELIST") ) ) {
    print YELLOW
"[INFO] - Skipping bandwidth check! Feature list \"$FEATURELIST\" missing from /var/cpanel/features/\n";
}
else {
    my ($bwused) =
qx[ uapi --user=$username StatsBar get_stats display=bandwidthusage | grep 'count:' | grep -v '_count' ];
    chomp($bwused);
    my ($bwmax) =
qx[ uapi --user=$username StatsBar get_stats display=bandwidthusage | grep 'max:' | grep -v '_max' ];
    chomp($bwmax);
    $bwused =~ s/count://g;
    $bwmax =~ s/max://g;
    $bwused = alltrim($bwused);
    $bwmax  = alltrim($bwmax);
    print "Bandwidth: $bwused used of $bwmax allowed\n";
}

# Check for custom style (Paper Lantern Theme)
my $custom_style_path = "$RealHome/var/cpanel/styled/current_style";
my $custom_style_link;
my $custom_style;
my @custom_style_array;
my $custom_style_array;
if ( -e ("$custom_style_path") ) {
    $custom_style_link  = readlink($custom_style_path);
    @custom_style_array = split( "\/", $custom_style_link );
    $custom_style       = $custom_style_array[-1];
}

print WHITE "Hosting Package: "
  . CYAN $PACKAGE
  . WHITE " ("
  . "Feature List: "
  . GREEN $FEATURELIST
  . WHITE ") "
  . $HAS_AUTOSSL_TEXT . "\n";
my $X3WARN = "";
if ( $THEME eq "x3" ) {
    $X3WARN = RED
"[WARN] - x3 Theme deprecated. cPanel UI not loading?  This is probably why!";
}
if ($custom_style) {
    print WHITE "Theme: "
      . CYAN $THEME
      . " (Style: $custom_style) "
      . $X3WARN . "\n";
}
else {
    print WHITE "Theme: " . CYAN $THEME . " " . $X3WARN . "\n";
}
print WHITE "Max Addon/Alias/Sub Domains: "
  . CYAN $MAXADDON
  . WHITE " / "
  . CYAN $MAXPARK
  . WHITE " / "
  . CYAN $MAXSUB . "\n";
print WHITE "Max SQL Databases: " . CYAN $MAXSQL . "\n";
print WHITE "Max Mailman Lists: " . CYAN $MAXLST . "\n";
print WHITE "Max FTP Accounts: " . CYAN $MAXFTP . "\n";
print WHITE "Max Bandwidth Allowed: " . CYAN $BWLIMIT . " MB\n";
print WHITE "AutoSSL Enabled: " . CYAN $HAS_AUTOSSL . "\n";
print WHITE "Backup Enabled: "
  . CYAN $BACKUPENABLED
  . GREEN " / "
  . WHITE "LEGACY: "
  . CYAN $LEGACYBACKUP . "\n";

my $PHPDefaultVersion;
my $PHPversion;
my $isEA4       = 0;
my $cageFSStats = check_for_cagefs();
if ($cageFSStats) {
    print WHITE "CageFS: " . CYAN $cageFSStats . "\n";
}
else {
    print WHITE "CageFS: " . CYAN . "Not installed!\n";
}

# Check for php-selector (CloudLinux)
my $clPHPVer = 0;
if ( -e ("$RealHome/.cl.selector/defaults.cfg") and $cageFSStats eq "Enabled" )
{
    my $clPHP = qx[ egrep '^php' $RealHome/.cl.selector/defaults.cfg ];
    $clPHPVer =~ s/\s+//g;
    ($clPHPVer) = ( split( /=/, $clPHP ) )[1];
    chomp($clPHPVer);
    $clPHPVer = alltrim($clPHPVer);
    if ($clPHPVer) {
        print WHITE "CloudLinux PHP Version: " . CYAN $clPHPVer . "\n";

        my $PHPiniFile =
qx[ su -s /bin/bash $username -c "php -i | grep '^Configuration File'" ];
        my $PHPiniLoad =
qx[ su -s /bin/bash $username -c "php -i | grep '^Loaded Configuration File'" ];
        my $PHPiniScan =
          qx[ su -s /bin/bash $username -c "php -i | grep '^Scan this dir'" ];
        chomp($PHPiniFile);
        chomp($PHPiniLoad);
        chomp($PHPiniScan);
        if ( $cageFSStats and $cageFSStats eq "Enabled" ) {
            print expand( YELLOW "\t \\_ $PHPiniFile\n" );
            print expand( YELLOW "\t \\_ $PHPiniLoad\n" );
            print expand( YELLOW "\t \\_ $PHPiniScan\n" );
        }
    }
}

my $skipEA4 = 0;
if ( $clPHPVer and $cageFSStats eq "Enabled" ) {
    $skipEA4 = 1;
}

$isEA4 = isEA4();
my $clPHPActive = 0;
if ( $isEA4 and !$skipEA4 ) {
    $PHPDefaultVersion = get_system_php_version();
    if ( $PHPDefaultVersion eq "" ) {
        $PHPDefaultVersion = "UNKNOWN";
    }
    $PHPversion = get_php_version();
    if ( $PHPversion eq "" ) {
        $PHPversion = "inherit";
    }
    if ( $PHPversion eq "inherit" ) { $clPHPActive = 1; }
    print WHITE "[EA4] PHP Version: "
      . CYAN $PHPversion
      . " (System Default: $PHPDefaultVersion) ";

    # Check for ^suPHP_ConfigPath variable in .htaccess files
    my $suPHPConfPathFound;
    if ( -e ("$RealHome/public_html/.htaccess") ) {
        $suPHPConfPathFound =
          qx[ egrep '^suPHP_ConfigPath' "$RealHome/public_html/.htaccess" ];
    }

    if ( $clPHPActive and $cageFSStats eq "Enabled" ) {
        print MAGENTA "CloudLinux PHP Version has precedence\n";
    }
    else {
        print MAGENTA "cPanel EA4 PHP Version has precedence\n";
    }
    if ( -e ("/var/cpanel/userdata/$username/$MAINDOMAIN.php-fpm.yaml") ) {
        print YELLOW "PHP-FPM pool detected\n";
    }
    my $old_fpm_flag =
      qx[ whmapi1 php_get_old_fpm_flag | grep 'old_fpm_flag: 1' ];
    if ($old_fpm_flag) {
        print RED "[WARN] Old PHP-FPM flags found!\n";
        print
"Look in /etc/apache2/conf.d/userdata/std/2_4/$username/$MAINDOMAIN/ for an fpm.conf file.\n";
    }

    # Get php.ini config info
    if ( $PHPversion eq "inherit" and $cageFSStats ne "Enabled" ) {
        $PHPversion = $PHPDefaultVersion;
    }
    if ( -e ("/etc/scl/conf/$PHPversion")
        or ( -e ("/etc/scl/prefixes/$PHPversion") ) )
    {
        my $PHPiniFile =
qx[ /usr/bin/scl enable $PHPversion "php -i" | grep '^Configuration File' ];
        my $PHPiniLoad =
qx[ /usr/bin/scl enable $PHPversion "php -i" | grep '^Loaded Configuration File' ];
        my $PHPiniScan =
qx[ /usr/bin/scl enable $PHPversion "php -i" | grep '^Scan this dir' ];

        if ($suPHPConfPathFound) {
            print YELLOW "[NOTE]"
              . WHITE
              . " - suPHP_ConfigPath found in "
              . CYAN
              . $suPHPConfPathFound;
            my ($UsersuPHPConfPath) =
              ( split( /\s+/, $suPHPConfPathFound ) )[1];
            $PHPiniFile =
              "Configuration File (php.ini) Path => $UsersuPHPConfPath";
            $PHPiniLoad = "Loaded Configuration File => $UsersuPHPConfPath";
            $PHPiniScan = "Scan this dir for additional .ini files => None";
        }
        chomp($PHPiniFile);
        chomp($PHPiniLoad);
        chomp($PHPiniScan);
        print expand( YELLOW "\t \\_ $PHPiniFile\n" );
        print expand( YELLOW "\t \\_ $PHPiniLoad\n" );
        print expand( YELLOW "\t \\_ $PHPiniScan\n" );
    }

    if ( !( -e ("$RealHome/public_html") ) ) {
        $skipfind = 1;
    }

    # Search /home/username for any php.ini files (unless --skipfind)
    if ( $skipfind == 0 ) {
        my @anyINI = qx [ find $RealHome -maxdepth 3 -name '*.ini' ];
        my $anyINIfile;
        if (@anyINI) {
            print GREEN "Custom *.ini files found in: \n";
            foreach $anyINIfile (@anyINI) {
                chomp($anyINIfile);
                print expand( YELLOW "\t \\_ $anyINIfile\n" );
            }
        }
        print "\n";
    }
}

# Check for custom (user) httpd.conf files
if ( -e ("/etc/apache2/conf.d/userdata/std/2/$username/$MAINDOMAIN/") ) {
    print expand( YELLOW
"\t[INFO] Found userdata directory: /etc/apache2/conf.d/userdata/std/2/$username/$MAINDOMAIN\n"
    );
}
if ( -e ("/etc/apache2/conf.d/userdata/ssl/2/$username/$MAINDOMAIN/") ) {
    print expand( YELLOW
"\t[INFO] Found userdata directory: /etc/apache2/conf.d/userdata/ssl/2/$username/$MAINDOMAIN\n"
    );
}

my $IS_IP_ON_SERVER = qx[ ip addr | grep $IPADDR ];
my $NOTONSERVER     = "[ Is configured on this server ] ";
if ( $IS_IP_ON_SERVER eq "" ) {
    $NOTONSERVER = "[ Not configured on this server ]";
}
print WHITE "IP address: "
  . CYAN $IPADDR
  . WHITE " ("
  . CYAN $IPTYPE
  . WHITE ") - $NOTONSERVER\n";
my $defaultsite       = 0;
my $TotalARecords     = @ResolvedIP;
my $ConnectionTimeout = 0;
if ( @ResolvedIP[4] =~ m/no servers could be reached/ ) {
    $TotalARecords     = 0;
    $ConnectionTimeout = 1;
}
my $ResolvesToDetail = "";
print WHITE "Resolves to IP: ";
if ( $TotalARecords > 1 ) {
    print "(multiple A records found) \n";
    foreach $ResolvedIP (@ResolvedIP) {
        chomp($ResolvedIP);
        $ResolvesToDetail = check_resolved_ip($ResolvedIP);
        print expand(
            CYAN "\t \\_" . $ResolvedIP . " " . RED $ResolvesToDetail . "\n" );
    }
}
else {    ##  ONLY 1 A RECORED RETURNED.
    $ResolvedIP = @ResolvedIP[0];
    chomp($ResolvedIP);
    if ($ConnectionTimeout) {
        $ResolvedIP = "";
    }
    if ( $TotalARecords == 0 and $ResolvedIP eq "" ) {
        print "DOES NOT RESOLVE!\n";
        $defaultsite = 1;
    }
    else {
        $ResolvesToDetail = check_resolved_ip($ResolvedIP);
        print CYAN $ResolvedIP . " " . RED $ResolvesToDetail;
    }
    print "\n";
}

# Check to see if domain name is in httpd.conf
my $FoundInHTTPDconf;
if ($isEA4) {
    if ($IS_USERNAME) {
        $FoundInHTTPDconf = qx[ grep -w '$QUERY' /etc/apache2/conf/httpd.conf ];
    }
    else {
        $FoundInHTTPDconf =
          qx[ grep -w '$MAINDOMAIN' /etc/apache2/conf/httpd.conf ];
    }
}
else {
    if ($IS_USERNAME) {
        $FoundInHTTPDconf =
          qx[ grep -w '$QUERY' /usr/local/apache/conf/httpd.conf ];
    }
    else {
        $FoundInHTTPDconf =
          qx[ grep -w '$MAINDOMAIN' /usr/local/apache/conf/httpd.conf ];
    }
}
if ( !($FoundInHTTPDconf) ) {
    if ($IS_USERNAME) {
        print RED "[WARN] "
          . YELLOW "- $QUERY is missing from httpd.conf file!\n";
    }
    else {
        print RED "[WARN] "
          . YELLOW "- $MAINDOMAIN is missing from httpd.conf file!\n";
    }
    $defaultsite = 1;
}

if ($defaultsite) {
    print YELLOW
"Not seeing the site you're expecting (or defaultwebpage.cgi)? - This may be why!\n";
}

if ( $all or $mail ) {
    display_mail_info();
}

# Last Login IP
if ($LastLoginIP) {
    print WHITE "Last logged in to cPanel from IP: " . CYAN $LastLoginIP . "\n";
}

print WHITE "Has been a customer since " . CYAN $STARTDATE . "\n";

# Check to see if the $username is in /var/cpanel/suspended directory
my $SUSP   = 0;
my $REASON = "";
if ( -e ("/var/cpanel/suspended/$username") ) {
    $REASON = `cat /var/cpanel/suspended/$username`;
    chomp($REASON);
    $SUSP = 1;
}

print WHITE "Suspended: ";
if ($SUSP) {
    print RED "YES! (Since: " . scalar localtime($SUSPEND_TIME) . ")";
    print WHITE " - Reason: " . CYAN $REASON unless ( $REASON eq "" );
}
else {
    print GREEN "No";
}
print "\n";
print WHITE "Count of other domains: ["
  . YELLOW "SUB: "
  . GREEN $subcnt
  . WHITE "] - ["
  . YELLOW "ALIASES "
  . GREEN $parkcnt
  . WHITE "] - ["
  . YELLOW "ADDONS: "
  . GREEN $addoncnt
  . WHITE "]\n";

my $TotalDomainCnt = $subcnt + $parkcnt + $addoncnt + 1;
my $DNSLinesCnt    = qx[ grep -c '^DNS' /var/cpanel/users/$username ];
if ( $DNSLinesCnt != $TotalDomainCnt ) {
    print expand(
            RED "\t \\_ [WARN]: One or more DNS lines may be missing from "
          . BOLD CYAN "/var/cpanel/users/$username\n" );
}
border();

my $SUB   = "";
my $PARK  = "";
my $ADDON = "";
if ( $subcnt + $addoncnt + $parkcnt > 1
    and ( $all or $listsubs or $listaddons or $listparked or $listaliased ) )
{
    print WHITE "The following are associated with "
      . CYAN $MAINDOMAIN
      . WHITE " ("
      . GREEN $username
      . WHITE ")\n";
    smborder();
}
if ( $all or $listsubs ) {
    print YELLOW "Sub Domains: ";
    if ( $subcnt > 0 and ( $all or $listsubs ) ) {
        print "\n";
        foreach $SUB (@SUBDOMAINS) {
            chomp($SUB);
            print expand( YELLOW "\t \\_ $SUB\n" );
        }
    }
    else {
        print MAGENTA "No Sub Domains found for "
          . CYAN $MAINDOMAIN
          . WHITE " ("
          . GREEN $username
          . WHITE ")\n";
    }
    smborder();
}

if ( $all or $listaddons ) {
    print YELLOW "Addon Domains: ";
    if ( $addoncnt > 0 and ( $all or $listaddons ) ) {
        print "\n";
        foreach $ADDON (@ADDONDOMAINS) {
            chomp($ADDON);
            print expand( YELLOW "\t \\_ $ADDON\n" );
        }
    }
    else {
        print MAGENTA "No Addon Domains found for "
          . CYAN $MAINDOMAIN
          . WHITE " ("
          . GREEN $username
          . WHITE ")\n";
    }
    smborder();
}

if ( $all or $listparked or $listaliased ) {
    print YELLOW "Aliased Domains: ";
    if ( $parkcnt > 0 and ( $all or $listparked or $listaliased ) ) {
        print "\n";
        foreach $PARK (@PARKEDDOMAINS) {
            chomp($PARK);
            print expand( YELLOW "\t \\_ $PARK\n" );
        }
    }
    else {
        print MAGENTA "No Aliased Domains found for "
          . CYAN $MAINDOMAIN
          . WHITE " ("
          . GREEN $username
          . WHITE ")\n";
    }
    smborder();
}

# RESELLER INFO
if ( $reselleraccts or $all ) {
    if ($all) { border(); }
    my $owned_by_reseller = "";
    if ( $Is_Reseller and $ResellerAcctsCnt > 0 ) {
        print CYAN $MAINDOMAIN
          . WHITE
" is a reseller and has the following ($ResellerAcctsCnt) accounts under it\n";
        shift @ACCTSOWNEDBYRESELLER;
        my @SORTEDRESELLERACCTS = sort(@ACCTSOWNEDBYRESELLER);
        foreach $owned_by_reseller (@SORTEDRESELLERACCTS) {
            chomp($owned_by_reseller);
            print expand( BOLD YELLOW ON_BLACK "\t \\_ $owned_by_reseller\n" );
        }
        border();
    }
    else {
        print WHITE "No Reseller accounts found for "
          . CYAN $MAINDOMAIN
          . WHITE " ("
          . GREEN $username
          . WHITE ")\n";
        border();
    }
}

if ( $resellerperms or $all ) {
    if ($all) { border(); }
    my $DefaultPerm  = "";
    my $defaultRPerm = "";
    my @defaultperms =
      qw( acct-summary basic-system-info basic-whm-functions cors-proxy-get cpanel-api cpanel-integration create-user-session digest-auth generate-email-config list-pkgs manage-api-tokens manage-dns-records manage-oidc manage-styles mysql-info ns-config public-contact ssl-info track-email );
    if ($Is_Reseller) {
        open( RESELLERS, "/var/cpanel/resellers" );
        my @RESELLERS = <RESELLERS>;
        close(RESELLERS);
        my $resellerline = "";
        my @rperms       = undef;
        my $rperm        = "";
        print CYAN "The reseller " . $MAINDOMAIN
          . WHITE " has the following reseller permissions\n";
        foreach $resellerline (@RESELLERS) {
            chomp($resellerline);
            my ( $reseller, $rperms ) = ( split( /:/, $resellerline ) );
            if ( $reseller eq $username ) {
                my @rperms = split /,/, $rperms;
                foreach $rperm (@rperms) {
                    chomp($rperm);
                    foreach $defaultRPerm (@defaultperms) {
                        chomp($defaultRPerm);
                        if ( $rperm =~ $defaultRPerm ) {
                            $DefaultPerm = BLUE ON_BLACK "[DEFAULT]";
                            last;
                        }
                        else {
                            $DefaultPerm = "";
                        }
                    }
                    print expand(
                        BOLD YELLOW ON_BLACK "\t \\_ $rperm " . $DefaultPerm );
                    if ( $rperm eq "all" ) {
                        print RED "[WARN] - HAS ROOT PRIVILEGES!!!\n";
                    }
                    else {
                        print "\n";
                    }
                }
            }
        }
        border();
    }
}

# MySQL INFO
if ( $listdbs or $all ) {
    my @USERDBS  = undef;
    my @DBSIZE   = undef;
    my $USERDB   = "";
    my $SIZEOFDB = "";
    my $DBNAME   = "";
    my $DBSIZE   = "";

    # MySQL username can only be the first 8 characters of $usrename
    my $first8;
    if ($DBPrefix) {
        $first8 = substr( $username, 0, 8 );
        @USERDBS = qx[ echo "SHOW DATABASES like '$first8%'" | mysql -BN ];
    }
    else {
        @USERDBS =

          # THIS BELOW FAILS IF DB PREFIX IS OFF!!!
          qx[ echo "SHOW DATABASES like = '$username%'" | mysql -BN ];
    }
    my $DBCNT = @USERDBS;
    if ( $DBCNT == 0 ) {
        print WHITE "No MySQL databases found for "
          . CYAN $MAINDOMAIN
          . WHITE " ("
          . GREEN $username
          . WHITE ")\n";
    }
    else {
        print WHITE
          "The following ($DBCNT) MySQL databases can be found under: "
          . GREEN $username . "\n";
        foreach $USERDB (@USERDBS) {
            chomp($USERDB);
            $USERDB =~ s/\\//g;
            print expand( YELLOW "\t \\_ " . $USERDB . "\n" );
        }
    }
    smborder();

    # PostGreSQL INFO
    my $psql_running = 0;
    if (qx[ ps ax | grep postgres | grep -v grep ]) { $psql_running = 1; }
    if ( -e ("/usr/bin/psql") and $psql_running )
    {    ## PostGreSQL is installed and running
        my @PSQLDBS = undef;
        my $PgDb    = "";
        @PSQLDBS =
qx[ /usr/bin/psql -U postgres -c "SELECT datname FROM pg_catalog.pg_database WHERE datistemplate='f' AND datname !='postgres'" | grep -v '\-' | grep -v 'datname' | grep -v ' row' ];
        pop(@PSQLDBS);
        my $PgDbCount = @PSQLDBS;
        if ( $PgDbCount == 0 ) {
            print WHITE "No PostGreSQL databases found for "
              . CYAN $MAINDOMAIN
              . WHITE " ("
              . GREEN $username
              . WHITE ")\n";
        }
        else {
            print WHITE
"The following ($PgDbCount) PostGreSQL databases can be found under: "
              . GREEN $username . "\n";
            my $pg_table  = "";
            my @PG_TABLES = undef;
            foreach $PgDb (@PSQLDBS) {
                chomp($PgDb);
                $PgDb = substr( $PgDb, 1 );
                print expand( YELLOW "\t \\_" . $PgDb . "\n" );
            }
        }
    }
    else {
        print RED "PostGreSQL server is not installed (or running) on "
          . MAGENTA $HOSTNAME . "\n";
    }
    border();
}

if ( $listssls or $all ) {
    if ( $CPVersion lt "11.68.0.0" ) {
        oldlistssls();
    }
    else {
        $sslsyscertdir = "/var/cpanel/ssl/apache_tls/";
        if ( -e ("$sslsyscertdir/$MAINDOMAIN/certificates") ) {
            $sslsubject =
qx[ openssl x509 -in "$sslsyscertdir/$MAINDOMAIN/certificates" -subject -noout ];
            $startdate =
qx[ openssl x509 -in "$sslsyscertdir/$MAINDOMAIN/certificates" -startdate -noout ];
            $expiredate =
qx[ openssl x509 -in "$sslsyscertdir/$MAINDOMAIN/certificates" -enddate -noout ];
            $isSelfSigned =
qx[ openssl verify "$sslsyscertdir/$MAINDOMAIN/certificates" | grep 'self signed certificate' ];

            print WHITE "SSL Certificates installed under "
              . CYAN $MAINDOMAIN
              . WHITE " ("
              . GREEN $username
              . WHITE ")\n";
            dispSSLdata($MAINDOMAIN);
            print WHITE "Protecting the following Subject Alternative Names:\n";
            my $SAN;
            my @getSANS =
qx[ openssl x509 -in "$sslsyscertdir/$MAINDOMAIN/certificates" -noout -text | grep -oP '(?<=DNS:)[a-z0-9.-]+' ];

            foreach $SAN (@getSANS) {
                chomp($SAN);
                my $OCSPstatus =
qx[ openssl s_client -connect $SAN:443 -servername $SAN -status <<<quit 2>&1 | egrep 'Cert Status:' ];
                chomp($OCSPstatus);
                print expand( YELLOW "\t \\_ " . CYAN $SAN);
                if ($OCSPstatus) {
                    print BOLD CYAN " - OCSP: "
                      . BOLD MAGENTA substr( $OCSPstatus, 17 );
                }
                print "\n";
            }
        }
        else {
            print YELLOW $MAINDOMAIN . "\n";
            print expand( WHITE "\t \\_ " . CYAN . "No SSL found.\n" );
        }

        # Check for excluded domains for AutoSSL
        my @isExcluded =
qx[ uapi --user=$username SSL get_autossl_excluded_domains | grep 'excluded_domain:' ];
        if ( (@isExcluded) ) {
            my $isExcluded;
            print BOLD MAGENTA
              "*** The following domains are excluded from AutoSSL ***\n";
            for $isExcluded (@isExcluded) {
                chomp($isExcluded);
                print expand(
                    YELLOW "\t \\_ " . CYAN substr( $isExcluded, 23 ) . "\n" );
            }
        }

        foreach $SUB (@SUBDOMAINS) {
            chomp($SUB);
            if ( -e ("$sslsyscertdir/$SUB/certificates") ) {
                $sslsubject =
qx[ openssl x509 -in "$sslsyscertdir/$SUB/certificates" -subject -noout ];
                $startdate =
qx[ openssl x509 -in "$sslsyscertdir/$SUB/certificates" -startdate -noout ];
                $expiredate =
qx[ openssl x509 -in "$sslsyscertdir/$SUB/certificates" -enddate -noout ];
                $isSelfSigned =
qx[ openssl verify "$sslsyscertdir/$SUB/certificates" | grep 'self signed certificate' ];
                dispSSLdata($SUB);
                print WHITE
                  "Protecting the following Subject Alternative Names:\n";
                my $SAN;
                my @getSANS =
qx[ openssl x509 -in "$sslsyscertdir/$SUB/certificates" -noout -text | grep -oP '(?<=DNS:)[a-z0-9.-]+' ];

                foreach $SAN (@getSANS) {
                    chomp($SAN);
                    print expand( YELLOW "\t \\_ " . CYAN $SAN . "\n" );
                }
            }
            else {
                print YELLOW $SUB . "\n";
                print expand( WHITE "\t \\_ " . CYAN . "No SSL found.\n" );
            }
        }

# Check for pending AutoSSL orders here (uses whmapi1 get_autossl_pending_queue (62.0.26+ only)
        if ( $SSLProvider eq " cPanel" ) {
            print "\nChecking for pending AutoSSL orders: \n";
            my $SSL_PENDING =
qx[ whmapi1 get_autossl_pending_queue | grep -B3 'user: $username' ];
            if ($SSL_PENDING) {
                my $NEW_SSL_PENDING;
                ( $NEW_SSL_PENDING = $SSL_PENDING ) =~
s/order_item_id: /order_item_id: https:\/\/manage2.cpanel.net\/certificate.cgi\?oii=/g;
                $SSL_PENDING = $NEW_SSL_PENDING;
                print expand( GREEN "\t \\_ \n" );
                print GREEN "$SSL_PENDING";
            }
            else {
                print expand( GREEN "\t \\_ None" );
            }
            print "\n";
        }

        # Check for purchased SSL's
        print "Checking for pending SSL Orders (non-autossl): \n";
        if ( -e ("$RealHome/.cpanel/ssl/pending_queue.json") ) {
            my ($PendingSSLOrder) = (
                split(
                    /\s+/,
qx[ python -mjson.tool $RealHome/.cpanel/ssl/pending_queue.json|grep -A1 cPStore ]
                )
            )[3];
            $PendingSSLOrder =~ s/\"//g;
            $PendingSSLOrder =~ s/,//g;
            $PendingSSLOrder =~ s/://g;
            print expand( CYAN "\t \\_ Pending order number: "
                  . GREEN
                  . "https://manage2.cpanel.net/certificate.cgi?oii=$PendingSSLOrder\n"
            );
        }
        else {
            print expand( GREEN "\t \\_ None\n" );
        }

        # Check for CAA records here.
        my @HasCAA;
        print "Checking for CAA records: \n";
        my $TLD;
        my $CAARecord;
        if ($IS_USERNAME) {
            $TLD = substr( $MAINDOMAIN, rindex( $MAINDOMAIN, "." ) + 1 );
            $CAADOMAIN = $MAINDOMAIN;
        }
        else {
            $TLD = substr( $QUERY, rindex( $QUERY, "." ) + 1 );
            $CAADOMAIN = $QUERY;
        }
        chomp($TLD);
        my $CAAFound = 0;
        while ( $CAADOMAIN ne $TLD ) {
            my $DNSSEC_error =
qx[ dig +tries=2 +time=5 \@208.67.222.222 $DOMAIN CAA | grep 'status: SERVFAIL' ];
            if ($DNSSEC_error) {
                print RED "[WARN] " . WHITE "CAA record check failed with DNSSEC error!\n";
                border();
                return;
            }
            @HasCAA =
qx[ dig +tries=2 +time=5 \@208.67.220.220 +noall +answer $CAADOMAIN CAA ];
            if (@HasCAA) {
                print YELLOW "[NOTE] * CAA records were found for $CAADOMAIN\n";
                print GREEN
"SSL Certificates can only be issued from the following CA's:\n";
                my ( $CAARecord1, $CAARecord2, $CAARecord3 );
                foreach $CAARecord (@HasCAA) {
                    chomp($CAARecord);
                    ( $CAARecord1, $CAARecord2, $CAARecord3 ) =
                      ( split( /\s+/, $CAARecord ) )[ 4, 5, 6 ];
                    print expand(
                        CYAN "\t \\_ $CAARecord1 $CAARecord2 $CAARecord3\n" );
                }
                $CAAFound = 1;
            }
            parsedomain($CAADOMAIN);
        }
        if ( $CAAFound == 0 ) {
            print expand( GREEN "\t \\_ None\n" );
        }
        border();
    }
}

print "</c>\n" unless ($nocodeblock);
exit;

sub Usage {
    print WHITE "\nUsage: "
      . CYAN "acctinfo"
      . WHITE " [options] domainname.tld or cPUsername [options]\n\n";
    print YELLOW "Examples: \n"
      . CYAN "acctinfo"
      . WHITE " --listdbs somedomain.net\n";
    print expand( GREEN
"\t Lists any MySQL databases (and their sizes) as well as any PostGreSQL\n\t databases for somedomain.net\n\n"
    );
    print CYAN "acctinfo" . WHITE " --listsubs cptestdo\n";
    print expand(
        GREEN "\t Lists all sub domains under the cptestdo user name.\n\n" );
    print CYAN "acctinfo" . WHITE " --listaddons cptestdomain.net\n";
    print expand( GREEN
"\t Lists all addon domains under the cptestdomain.net domain name.\n\n"
    );
    print CYAN "acctinfo" . WHITE " --listalias cptestdomain.net\n";
    print expand( GREEN
"\t Lists all alias (parked) domains under the cptestdomain.net domain name.\n\n"
    );
    print CYAN "acctinfo" . WHITE " --reselleraccts cptestdo\n";
    print expand( GREEN
"\t Lists reseller information and domains under the cptestdo user name.\n\n"
    );
    print CYAN "acctinfo" . WHITE " --resellerperms cptestdo\n";
    print expand( GREEN
          "\t Lists reseller permissions under the cptestdo user name.\n\n" );
    print CYAN "acctinfo" . WHITE " --listssls cptestdomain.net\n";
    print expand( GREEN
          "\t Lists any SSL's under the cptestdomain.net domain name.\n\n" );
    print CYAN "acctinfo" . WHITE " --cruft cptestdomain.net\n";
    print expand( GREEN "\t Perform a cruft check on cptestdomain.net.\n\n" );
    print CYAN "acctinfo" . WHITE " --mail cptestdomain.net\n";
    print expand(
        GREEN "\t Display mail information for cptestdomain.net.\n\n" );
    print CYAN "acctinfo" . WHITE " --scan cptest\n";
    print expand(
        GREEN "\t Scan users home directory for known infection strings.\n\n" );
    print CYAN "acctinfo" . WHITE " --all cptestdomain.net\n";
    print expand(
        GREEN "\t Lists everything for the cptestdomain.net domain name.\n\n" );
    print CYAN "acctinfo" . WHITE " --help\n";
    print expand( GREEN
"\t Shows this usage information. (NOTE: [options] can go before or after domain/username).\n\n"
    );
    exit;
}

sub border {
    print MAGENTA ON_BLACK
"==============================================================================================\n";
    return;
}

sub smborder {
    print MAGENTA
"----------------------------------------------------------------------------------------------\n";
    return;
}

sub parsedomain {
    my $strip = index( $CAADOMAIN, "." );
    $CAADOMAIN = substr( $CAADOMAIN, $strip + 1 );
}

sub FindMainDomain() {
    $SearchFor = $_[0];
    my $MAINUSER     = "";
    my $TrueUserLine = "";
    open( TRUEUSER, "/etc/trueuserdomains" );
    my @TRUEUSERS = <TRUEUSER>;
    close(TRUEUSER);
    foreach $TrueUserLine (@TRUEUSERS) {
        chomp($TrueUserLine);
        ( $MAINDOMAIN, $MAINUSER ) = ( split( /:\s+/, $TrueUserLine ) );
        if ( $MAINUSER eq $SearchFor ) {
            return $MAINDOMAIN;
        }
    }
}

sub FindUser() {
    my $SearchFor = $_[0];
    my $UserLine  = "";
    my $TheDOMAIN = "";
    my $TheUSER   = "";
    open( USERDOMAIN, "/etc/userdomains" );
    my @USERDOMAINS = <USERDOMAIN>;
    close(USERDOMAIN);
    foreach $UserLine (@USERDOMAINS) {
        chomp($UserLine);
        ( $TheDOMAIN, $TheUSER ) = ( split( /:\s+/, $UserLine ) );
        if ( $TheDOMAIN eq $SearchFor ) {
            return $TheUSER;
        }
    }
}

sub check_cloudflare_ips {
    my $chkIP = $_[0];

    # Below IP's obtained from: https://www.cloudflare.com/ips
    my @cf_subnets   = qx[ curl -s https://www.cloudflare.com/ips-v4 ];
    my $cloudflareIP = 0;
    my $cf_subnet    = "";
    my @a            = split /\./, $chkIP;
    my $di           = getIp(@a);
    foreach $cf_subnet (@cf_subnets) {
        ( $a, $b ) = getNetwork($cf_subnet);
        if ( ( $di >= $a ) && ( $di <= $b ) ) { $cloudflareIP = 1; }
    }

    sub getIp {
        return ( $_[0] * 256 * 256 * 256 ) +
          ( $_[1] * 256 * 256 ) +
          ( $_[2] * 256 ) +
          $_[3];
    }

    sub getNetwork {
        @a = split( /[\/|\.]/, +shift );
        return ( getIp( @a[ 0 .. 3 ] ),
            ( getIp( @a[ 0 .. 3 ] ) + ( 2**( 32 - $a[4] ) ) ) );
    }
    return $cloudflareIP;
}

sub check_for_nat {
    return if ( !( -e ("/var/cpanel/cpnat") ) );
    my $chkIP = $_[0];
    open( CPNAT, "/var/cpanel/cpnat" );
    my @CPNAT = <CPNAT>;
    close(CPNAT);
    my $cpnat;
    foreach $cpnat (@CPNAT) {
        chomp($cpnat);
        my ( $outsideIP, $insideIP ) = ( split( /\s+/, $cpnat ) );
        chomp($outsideIP);
        chomp($insideIP);
        if ( $outsideIP eq $chkIP ) {
            return $insideIP;
        }
        if ( $insideIP eq $chkIP ) {
            return $outsideIP;
        }
    }
}

sub check_resolved_ip {
    my $IP2CHK = $_[0];
    my $RetVal = "";
    if ( $IP2CHK eq $IPADDR ) {
        $RetVal = GREEN . " [SAME]";
    }
    else {
        $defaultsite = 1;
    }
    my $Is_IP_OnServer = qx[ ip addr | grep '$IP2CHK' ];
    if ( !($Is_IP_OnServer) ) {
        $RetVal = $RetVal .= RED . " [Not on this server]";
        $defaultsite = 1;
    }
    my $IS_CLOUDFLARE = check_cloudflare_ips($IP2CHK);
    if ($IS_CLOUDFLARE) {
        $RetVal      = " <-- CloudFlare DNS";
        $defaultsite = 1;
    }
    my $IS_NAT = check_for_nat($IP2CHK);
    if ($IS_NAT) {
        $RetVal = " NAT detected ($IS_NAT => $IP2CHK)";
        if ( $IS_NAT eq $IPADDR ) {
            $RetVal = $RetVal .= GREEN . " [SAME]";
            $defaultsite = 0;
        }
    }
    my $Is_IP_OnServer = qx[ ip addr | grep '$IS_NAT' ];
    if ( !($Is_IP_OnServer) ) {
        $RetVal = $RetVal .= RED . " [Not on this server]";
        $defaultsite = 1;
    }
    return $RetVal;
}

sub cruft_check {
    border();
    print CYAN "CRUFT CHECK\n";
    border();
    my $maxwidth       = 25;
    my $file2search    = "";
    my $TheStatus      = "";
    my $spacer         = 0;
    my $len            = 0;
    my $filestatus     = "";
    my $TrueUserLine   = "";
    my $isTerminated   = 0;
    my $termdate       = "";
    my @temp           = undef;
    my $DNSLineCnt     = 0;
    my $TotalDomainCnt = 0;

   # Check /var/cpanel/accounting.log file here (for CREATE and/or REMOVE lines)
   # ONLY MAIN ACCT / DOMAIN is checked
    print BLUE "From your query of "
      . GREEN $QUERY
      . BLUE " I have determined:\n";
    my $isActive;
    my $is_acct;
    my $check_for;
    open( ACCOUNTING, "/var/cpanel/accounting.log" );
    foreach (<ACCOUNTING>) {
        @temp = split(/:/);
        if ($IS_USERNAME) {
            $check_for = ':' . $QUERY . '$';
        }
        else {
            $check_for = ':' . $QUERY . ':';
        }
        if (/$check_for/) {
            $is_acct = 1;
            if (/CREATE/) {
                $isActive     = 1;
                $isTerminated = 0;
                chomp( $username   = $temp[-1] );
                chomp( $MAINDOMAIN = $temp[-3] );
            }
            if (/REMOVE/) {
                chomp( $username   = $temp[-1] );
                chomp( $MAINDOMAIN = $temp[-2] );
                $isActive     = 0;
                $isTerminated = 1;
                @temp         = ();
                @temp         = split(/:/);
                $termdate     = @temp[0] . ":" . @temp[1] . ":" . @temp[2];
            }
        }
    }
    close(ACCOUNTING);
    if ($isTerminated) {  ## $is_acct is true if this is the main account/domain
        print "$MAINDOMAIN ($username) was terminated on $termdate\n";
    }
    if ($isActive) {
        print
"$MAINDOMAIN ($username) is active (according to /var/cpanel/accounting.log)\n";
        if ( $addoncnt > 0 ) {
            print "It has $addoncnt Addon domains\n";
        }
        if ( $subcnt > 0 ) {
            print "It has $subcnt Sub domains\n";
        }
        if ( $parkcnt > 0 ) {
            print "It has $parkcnt Aliased domains\n";
        }

        # Add up the total number of additional domains
        $TotalDomainCnt = $addoncnt + $subcnt + $parkcnt;

        # Now add one more to that for the main account
        $TotalDomainCnt++;

# Now count the number of "DNS" lines in /var/cpanel/users/$username and make sure
# it equalts $TotalDomainCnt.  Warn if it does NOT!
        $DNSLineCnt = qx[ grep -c '^DNS' /var/cpanel/users/$username ];
    }

    # END OF ACCOUNTING LOG CHECK

    my $useQuery = 0;
    if (    !$isActive
        and !$is_acct
        and !$isTerminated
        and !$MAINDOMAIN
        and !$username )
    {
        print
"No data found for your query of: $QUERY in /var/cpanel/accounting.log\n";
        print "Continuing search for $QUERY...\n";
    }
    my $isAddon;
    my $isSub;
    my $isParked;
    my $SubDomain;
    if ( !$isActive ) {
        $isAddon =
          qx[ grep '^$QUERY:' /etc/userdatadomains | grep '==addon==' ];
        if ($isAddon) {
            ($username) = ( split( /\s+/, $isAddon ) )[1];
            ($username) = ( split( /==/,  $username ) );
            ($isAddon)  = ( split( /:/,   $isAddon ) );
            print
"$QUERY has an entry in /etc/userdatadomains as an Addon Domain under the "
              . CYAN $username
              . WHITE " user\n";
        }
        $isSub = qx[ grep '^$QUERY:' /etc/userdatadomains | grep '==sub==' ];
        if ($isSub) {
            ($username) = ( split( /\s+/, $isSub ) )[1];
            ($username) = ( split( /==/,  $username ) );
            ($isSub)    = ( split( /:/,   $isSub ) );
            print
"$QUERY has an entry in /etc/userdatadomains as a Sub Domain under the "
              . CYAN $username
              . WHITE " user\n"
              unless ($isAddon);
        }
        $isParked =
          qx[ grep '^$QUERY:' /etc/userdatadomains | grep '==parked==' ];
        if ($isParked) {
            ($username) = ( split( /\s+/, $isParked ) )[1];
            ($username) = ( split( /==/,  $username ) );
            ($isParked) = ( split( /:/,   $isParked ) );
            print
"$QUERY has an entry in /etc/userdatadomains as a Aliased Domain under the "
              . CYAN $username
              . WHITE " user\n";
        }
        if ( !$MAINDOMAIN and $username ) {
            ($MAINDOMAIN) =
              ( split( /:/, qx[ grep '$username' /etc/trueuserdomains ] ) )[0];
            chomp($MAINDOMAIN);
        }
        $useQuery = ($IS_USERNAME) ? 1 : 0;
    }
    smborder();

    my @FILES2SEARCHUSER = qw(
      /etc/passwd
      /etc/group
      /etc/shadow
      /etc/gshadow
      /etc/quota.conf
      /etc/dbowners
      /etc/trueuserowners
      /var/cpanel/databases/users.db
      /etc/userdatadomains.json
    );

    my @FILES2SEARCH = qw(
      /etc/userdomains
      /etc/trueuserdomains
      /etc/userdatadomains
      /etc/domainusers
      /etc/localdomains
      /etc/remotedomains
      /etc/demousers
      /etc/email_send_limits
      /etc/demoids
      /etc/demodomains
      /etc/ssldomains
    );

    #	print "DEBUG: IS_USERNAME = $IS_USERNAME\n";
    #	print "DEBUG: MAINDOMAIN = $MAINDOMAIN\n";
    #	print "DEBUG: username = $username\n";
    #	print "DEBUG: QUERY = $QUERY\n";
    #	print "DEBUG: useQuery = $useQuery\n";
    my $file2searchu;
    print "Searching the following files for $username:\n";
    foreach $file2searchu (@FILES2SEARCHUSER) {
        chomp($file2searchu);
        if ( !( -s ($file2searchu) ) ) {
            my $filestat = $file2searchu . " is either empty or missing";
            my $fileskip = CYAN "[SKIPPING]";
            print_output( $filestat, $fileskip );
            next;
        }
        $filestatus = check_file_existance( $file2searchu, $username );
        if   ($filestatus) { $filestatus = GREEN "[EXISTS]"; }
        else               { $filestatus = RED "[MISSING]"; }
        print_output( $file2searchu, $filestatus );
    }
    if ($IS_USERNAME) {
        $QUERY = $MAINDOMAIN;
    }
    print "Searching the following files for $QUERY\n";
    foreach $file2search (@FILES2SEARCH) {
        chomp($file2search);
        if ( !( -s ($file2search) ) ) {
            my $filestat = $file2search . " is either empty or missing";
            my $fileskip = CYAN "[SKIPPING]";
            print_output( $filestat, $fileskip );
            next;
        }
        if ( $MAINDOMAIN eq "" ) {
            $MAINDOMAIN = $QUERY;
        }
        $filestatus = check_file_existance( $file2search, $QUERY );
        if   ($filestatus) { $filestatus = GREEN "[EXISTS]"; }
        else               { $filestatus = RED "[MISSING]"; }
        print_output( $file2search, $filestatus );
    }
    if ($username) {

        # Check for home directory and others to see if they exist
        my $hmCnt;
        my $dirstatus = check_dir("/$HOMEDIR/$username");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "$HOMEDIR/$username", $dirstatus );
        if ( $dirstatus =~ m/MISSING/ ) {
            if ($HOMEMATCH) {
                print "Checking other possible home directory locations...\n";

                # Now check HOMEMATCH 1 through 9.
                for ( $hmCnt = 1 ; $hmCnt < 10 ; $hmCnt = $hmCnt + 1 ) {

                    #my $dirstatus = check_dir("/$HOMEMATCH$hmCnt/$username");
                    my $dirstatus = check_dir("$HOMEDIR$hmCnt/$username");
                    if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
                    else              { $dirstatus = RED "[MISSING]"; }

                    #print_output( "/$HOMEMATCH$hmCnt/$username", $dirstatus );
                    print_output( "$HOMEDIR$hmCnt/$username", $dirstatus );
                    if ( $dirstatus =~ m/EXISTS/ ) {
                        last;
                    }
                }
            }
        }

        # Check /var/cpanel/userdata/$username
        my $dirstatus = check_dir("/var/cpanel/userdata/$username");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/var/cpanel/userdata/$username", $dirstatus );

        # Check main file in /var/cpanel/userdata/$username directory
        my $dirstatus = check_dir("/var/cpanel/userdata/$username/main");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/var/cpanel/userdata/$username/main", $dirstatus );

        # Check /var/cpanel/users/$username
        my $dirstatus = check_dir("/var/cpanel/users/$username");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/var/cpanel/users/$username", $dirstatus );
        if ( $DNSLineCnt != $TotalDomainCnt ) {
            print expand( RED
"\t \\_ [WARN]: One or more DNS lines may be missing from this file!\n"
            );
        }

        # Check if /var/cpanel/databases/grants_$username.yaml exists!
        my $dirstatus =
          check_dir("/var/cpanel/databases/grants_$username.yaml");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/var/cpanel/databases/grants_$username.yaml",
            $dirstatus );

        my $yaml_json = ( $CPVersion lt "11.50.0.0" ) ? "yaml" : "json";
        my $dirstatus = check_dir("/var/cpanel/databases/$username.$yaml_json");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/var/cpanel/databases/$username.$yaml_json",
            $dirstatus );
        my $dbindex =
          ( $CPVersion lt "11.50.0.0" )
          ? "/var/cpanel/databases/dbindex.db"
          : "/var/cpanel/databases/dbindex.db.json";
        my $dirstatus = check_file_existance( $dbindex, $username );
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( $dbindex, $dirstatus );
        my $dirstatus = check_dir("/etc/proftpd/$username");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/etc/proftpd/$username", $dirstatus );

        # Check for /var/cpanel/bandwidth/username.sqlite file.
        my $dirstatus = check_dir("/var/cpanel/bandwidth/$username.sqlite");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/var/cpanel/bandwidth/$username.sqlite", $dirstatus );

    }
    else {
        print "Could not determine username so skipping all username checks!\n";
    }
    if ( !$IS_USERNAME ) {

        # Check /etc/valiases/$QUERY
        my $dirstatus = check_dir("/etc/valiases/$QUERY");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/etc/valiases/$QUERY", $dirstatus );

        # Check /etc/vfilters/$QUERY
        my $dirstatus = check_dir("/etc/vfilters/$QUERY");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/etc/vfilters/$QUERY", $dirstatus );

        # Check /var/named/$QUERY.db file
        my $dirstatus = check_dir("/var/named/$QUERY.db");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/var/named/$QUERY.db", $dirstatus );

        # Check /etc/apache2/logs/domlogs/$QUERY
        if ($isAddon) {
            my $SubDomain = ( split( /\./, $QUERY ) )[0] . "." . $MAINDOMAIN;
            chomp($SubDomain);
            my $dirstatus = check_dir("/etc/apache2/logs/domlogs/$SubDomain");
            if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
            else              { $dirstatus = RED "[MISSING]"; }
            print_output( "/etc/apache2/logs/domlogs/$SubDomain", $dirstatus );
        }
        else {
            my $dirstatus = check_dir("/etc/apache2/logs/domlogs/$QUERY");
            if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
            else              { $dirstatus = RED "[MISSING]"; }
            print_output( "/etc/apache2/logs/domlogs/$QUERY", $dirstatus );
        }

        # Check /etc/named.conf file
        my $dirstatus = check_file_existance( "/etc/named.conf", $QUERY );
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/etc/named.conf", $dirstatus );

        my $isEA4 = isEA4();
        if ($isEA4) {
            my $dirstatus =
              check_file_existance( "/etc/apache2/conf/httpd.conf",
                $MAINDOMAIN );
            if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
            else              { $dirstatus = RED "[MISSING]"; }
            print_output( "/etc/apache2/conf/httpd.conf", $dirstatus );
        }
        else {
            my $dirstatus =
              check_file_existance( "/usr/local/apache/conf/httpd.conf",
                $MAINDOMAIN );
            if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
            else              { $dirstatus = RED "[MISSING]"; }
            print_output( "/usr/local/apache/conf/httpd.conf", $dirstatus );
        }

    }
    else {
        my $dirstatus = check_dir("/etc/valiases/$MAINDOMAIN");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/etc/valiases/$MAINDOMAIN", $dirstatus );

        # Check /etc/vfilters/$MAINDOMAIN
        my $dirstatus = check_dir("/etc/vfilters/$MAINDOMAIN");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/etc/vfilters/$MAINDOMAIN", $dirstatus );

        my $dirstatus = check_dir("/etc/vdomainaliases/$MAINDOMAIN");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/etc/vdomainaliases/$MAINDOMAIN", $dirstatus );

        # Check /var/named/$MAINDOMAIN.db file
        my $dirstatus = check_dir("/var/named/$MAINDOMAIN.db");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/var/named/$MAINDOMAIN.db", $dirstatus );

        # Check /etc/apache2/logs/domlogs/$MAINDOMAIN
        my $dirstatus = check_dir("/etc/apache2/logs/domlogs/$MAINDOMAIN");
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/etc/apache2/logs/domlogs/$MAINDOMAIN", $dirstatus );

        # Check /etc/named.conf file
        my $dirstatus = check_file_existance( "/etc/named.conf", $MAINDOMAIN );
        if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
        else              { $dirstatus = RED "[MISSING]"; }
        print_output( "/etc/named.conf", $dirstatus );

        my $isEA4 = isEA4();
        if ($isEA4) {
            my $dirstatus =
              check_file_existance( "/etc/apache2/conf/httpd.conf",
                $MAINDOMAIN );
            if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
            else              { $dirstatus = RED "[MISSING]"; }
            print_output( "/etc/apache2/conf/httpd.conf", $dirstatus );
        }
        else {
            my $dirstatus =
              check_file_existance( "/usr/local/apache/conf/httpd.conf",
                $MAINDOMAIN );
            if   ($dirstatus) { $dirstatus = GREEN "[EXISTS]"; }
            else              { $dirstatus = RED "[MISSING]"; }
            print_output( "/usr/local/apache/conf/httpd.conf", $dirstatus );
        }
    }

    # Check for DNS Clustering
    if ( -e "/var/cpanel/useclusteringdns" ) {
        print "Found DNS Cluster - checking...\n";
        opendir( CLUSTERS, "/var/cpanel/cluster/root/config" );
        my @DNSCLUSTERS = readdir(CLUSTERS);
        closedir(CLUSTERS);
        my ( $dnscluster, $QueryCluster );
        foreach $dnscluster (@DNSCLUSTERS) {
            chomp($dnscluster);
            if (   $dnscluster eq "."
                or $dnscluster eq ".."
                or $dnscluster =~ m/dnsrole/
                or $dnscluster =~ m/.cache/ )
            {
                next;
            }
            if ($IS_USERNAME) {
                $QueryCluster =
                  qx[ dig +tries=2 +time=5 \@$dnscluster $MAINDOMAIN +short ];
                if ($QueryCluster) {
                    print expand( YELLOW "\t \\_ $MAINDOMAIN "
                          . GREEN ON_BLACK
                          . "was found in "
                          . YELLOW $dnscluster
                          . "\n" );
                }
                else {
                    print expand( YELLOW "\t \\_ $MAINDOMAIN "
                          . RED
                          . "NOT found in "
                          . YELLOW $dnscluster
                          . "\n" );
                }
            }
            else {
                $QueryCluster =
                  qx[ dig +tries=2 +time=5 \@$dnscluster $QUERY +short ];
                if ($QueryCluster) {
                    print expand( YELLOW "\t \\_ $QUERY "
                          . GREEN ON_BLACK
                          . "was found in "
                          . $dnscluster
                          . "\n" );
                }
                else {
                    print expand( YELLOW "\t \\_ $QUERY "
                          . RED
                          . "NOT found in "
                          . YELLOW $dnscluster
                          . "\n" );
                }
            }
        }
    }

    # Check MySQL users table.
    my @MySQLUsers = undef;
    my @MySQLDBs   = undef;
    my $MySQLUser;
    my $MySQLDB;
    my $first8;
    if ($DBPrefix) {
        if ( length($username) > 8 ) {
            $first8 = substr( $username, 0, 8 );
        }
        else {
            $first8 = $username;
        }
    }
    else {
        $first8 = $username;
    }

    # Check for MySQL databases
    my @MySQLDBs       = qx[ mysql -BNe "show databases like '$first8%'" ];
    my @MySQLDBsUnique = uniq(@MySQLDBs);
    my $dbnum          = @MySQLDBsUnique;
    if ( $dbnum > 0 ) {
        print YELLOW "MySQL Databases Found\n";
        foreach $MySQLDB (@MySQLDBsUnique) {
            chomp($MySQLDB);
            print expand( WHITE "\t \\_ " . $MySQLDB . "\n" );
        }
    }

    # Check for database users
    if ( $first8 eq "" ) {
        print "Skipping MySQL User check - no username found!\n";
    }
    else {
        my @MySQLUsers =
qx[ echo "SELECT User from mysql.user WHERE User REGEXP '$first8'" | mysql -BN ];
        my @MySQLUsersUnique = uniq(@MySQLUsers);
        my $num              = @MySQLUsersUnique;
        if ( $num > 0 ) {
            print YELLOW "MySQL Users Found in MySQL.user table\n";
            foreach $MySQLUser (@MySQLUsersUnique) {
                chomp($MySQLUser);
                print expand( WHITE "\t \\_ " . $MySQLUser . "\n" );
            }
        }
    }

    # Check for postgres
    my $psql_running = 0;
    if (qx[ ps ax | grep postgres | grep -v grep ]) { $psql_running = 1; }
    if ( -e ("/usr/bin/psql") and $psql_running )
    {    ## PostGreSQL is installed and running
        my @check_postgres_users =
qx[ /usr/bin/psql -t -h localhost --username=postgres -c 'select usename from pg_user'|grep "$username" ];
        if (@check_postgres_users) {
            print YELLOW "PostGreSQL Users Found in pg_user database\n";
            my @postgres_users = split( "\n", "@check_postgres_users" );
            foreach (@postgres_users) {
                chomp($_);
                print expand( WHITE "\t \\_" . $_ . "\n" );
            }
        }
    }
    else {
        print "\nPostGreSQL server is not installed (or running) on "
          . MAGENTA $HOSTNAME . "\n";
    }
    border();
    print "</c>\n" unless ($nocodeblock);
    exit;
}

sub check_file_existance {
    my $TheFile         = $_[0];
    my $TheSearchString = $_[1];
    my @TheFileData     = undef;
    my $DataLine        = "";

    #my $FoundLine       = 0;
    my $FoundLine = "";
    if ( -e ($TheFile) ) {

        $FoundLine = qx[ grep -w '$TheSearchString' $TheFile ];
        if   ($FoundLine) { return 1; }
        else              { return 0; }
    }
}

sub print_output {
    my $DisplayName = $_[0];
    my $TheStatus   = $_[1];
    my $maxwidth    = 30;
    my $spacer      = 0;
    my $len         = length($DisplayName);
    $spacer = ( $maxwidth - $len ) + 50;
    print YELLOW "$DisplayName";
    printf "%" . $spacer . "s", $TheStatus;
    print "\n";
    select( undef, undef, undef, 0.25 );
}

sub check_dir() {
    my $Dir2Check = $_[0];
    if ( -e ($Dir2Check) ) {
        return 1;
    }
    else {
        return 0;
    }
}

sub uniq {
    my %seen;
    grep !$seen{$_}++, @_;
}

# Taken from ssp - Thanks to Chris Dillon!
sub version_cmp {    # should only be used by version_compare()
    no warnings 'uninitialized'
      ;    # Prevent uninitialized value warnings when not using all 4 values
    my ( $a1, $b1, $c1, $d1 ) = split /[\._]/, $_[0];
    my ( $a2, $b2, $c2, $d2 ) = split /[\._]/, $_[1];
    return $a1 <=> $a2 || $b1 <=> $b2 || $c1 <=> $c2 || $d1 <=> $d2;
}

sub version_compare {

# example: return if version_compare($ver_string, qw( >= 1.2.3.3 ));
# Must be no more than four version numbers separated by periods and/or underscores.
    my ( $ver1, $mode, $ver2 ) = @_;
    return if ( $ver1 =~ /[^\._0-9]/ );
    return if ( $ver2 =~ /[^\._0-9]/ );

    # Shamelessly copied the comparison logic out of Cpanel::Version::Compare
    my %modes = (
        '>' => sub {
            return if $_[0] eq $_[1];
            return version_cmp(@_) > 0;
        },
        '<' => sub {
            return if $_[0] eq $_[1];
            return version_cmp(@_) < 0;
        },
        '==' => sub { return $_[0] eq $_[1] || version_cmp(@_) == 0; },
        '!=' => sub { return $_[0] ne $_[1] && version_cmp(@_) != 0; },
        '>=' => sub {
            return 1 if $_[0] eq $_[1];
            return version_cmp(@_) >= 0;
        },
        '<=' => sub {
            return 1 if $_[0] eq $_[1];
            return version_cmp(@_) <= 0;
        }
    );
    return if ( !exists $modes{$mode} );
    return $modes{$mode}->( $ver1, $ver2 );
}

# ripped from /usr/local/cpanel/Cpanel/Sys/OS.pm
sub get_release_version {
    my $ises = 0;
    my $ver;

    if ( open my $fh, '<', '/etc/redhat-release' ) {
        my $line = readline $fh;
        close $fh;
        chomp $line;
        if ( $line =~ m/(?:Corporate|Advanced\sServer|Enterprise)/i ) {
            $ises = 1;
        }
        elsif ( $line =~ /CloudLinux|CentOS/i ) { $ises = 2; }
        elsif ( $line =~ /WhiteBox/i )          { $ises = 3; }
        elsif ( $line =~ /caos/i )              { $ises = 4; }
        if    ( $line =~ /(\d+\.\d+)/ )         { $ver  = $1; }
        elsif ( $line =~ /(\d+)/ )              { $ver  = $1; }
    }

    if ($ises) {
        return ( $ver, $ises );
    }
    else {
        return ( $ver, 0 );
    }
}

sub check_for_cagefs() {
    return unless ( -e ("/usr/sbin/cagefsctl") );
    my $tcageFSStats = qx[ /usr/sbin/cagefsctl --user-status $username ];
    chomp($tcageFSStats);
    return $tcageFSStats;
}

sub get_php_version() {
    return unless ($isEA4);
    my $phpUserVersion;
    my $userdataline;
    my @USERDATA;

    # NOTE: If $IS_USERNAME, then use $MAINDOMAIN, otherwise use $QUERY.
    my $tcDomain = "";
    if ( $IS_USERNAME or $QUERY eq $MAINDOMAIN ) {
        $tcDomain = $MAINDOMAIN;
    }
    else {
        ($tcDomain) = ( split( /\./, $QUERY ) )[0];
        $tcDomain = $tcDomain . "." . $MAINDOMAIN;
    }
    open( USERDATA, "/var/cpanel/userdata/$username/$tcDomain" );
    @USERDATA = <USERDATA>;
    close(USERDATA);
    foreach $userdataline (@USERDATA) {
        if ( $userdataline =~ m/phpversion:/ ) {
            ($phpUserVersion) = ( split( /: /, $userdataline ) )[1];
            chomp($phpUserVersion);
        }
    }
    return $phpUserVersion;
}

sub get_system_php_version() {
    return unless ($isEA4);
    open( PHPCONF, "/etc/cpanel/ea4/php.conf" );
    my @PHPCONF = <PHPCONF>;
    close(PHPCONF);
    my $phpconfline;
    my $phpDefault;
    foreach $phpconfline (@PHPCONF) {
        chomp($phpconfline);
        if ( $phpconfline =~ m/default:/ ) {
            ($phpDefault) = ( split( /: /, $phpconfline ) )[1];
        }
    }
    return $phpDefault;
}

sub alltrim() {
    my $string2trim = $_[0];
    $string2trim =~ s/^\s*(.*?)\s*$/$1/;
    return $string2trim;
}

sub isEA4 {
    if ( -f "/etc/cpanel/ea4/is_ea4" ) {
        return 1;
    }
    return undef;
}

sub display_mail_info {
    if ($IS_USERNAME) {
        $DOMAIN = $MAINDOMAIN;
    }

    # first let's get the email accounts.
    my $emailacctline;
    opendir( EMAILACCTS, "$RealHome/mail/$DOMAIN" );
    my @EMAILACCTS = readdir(EMAILACCTS);
    closedir(EMAILACCTS);
    my @SORTED2 = sort(@EMAILACCTS);
    @EMAILACCTS = @SORTED2;
    smborder();

    # Check for suspended from outgoing email
    my $SMTPUserSusp = qx[ grep $username /etc/outgoing_mail_suspended_users ];
    if ($SMTPUserSusp) {
        print RED "[WARN] - $username is suspended from sending email\n";
    }

    # Check for hold from outgoing email
    my $SMTPUserHold = qx[ grep $username /etc/outgoing_mail_hold_users ];
    if ($SMTPUserHold) {
        print RED "[WARN] - $username is on hold from sending email\n";
    }

    if ( -s ("/etc/vdomainaliases/$DOMAIN") ) {
        print YELLOW "[INFO] - "
          . $DOMAIN
          . BOLD CYAN " listed in the /etc/vdomainaliases directory. "
          . YELLOW "Existing accounts/autoresponders\nwill NOT forward!\n";
    }

    print "Email accounts for $DOMAIN: \n";

    foreach $emailacctline (@EMAILACCTS) {
        chomp($emailacctline);
        next
          if ( $emailacctline =~
/^\.|^\.\.|new|cur|tmp|mailboxes|storage|maildirsize|maildirfolder|subscriptions|dovecot/
          );
        $emailacctline =~ s/\///g;    ## Strip trailing /
        print expand( CYAN "\t \\_ " . $emailacctline . "\@" . $DOMAIN . " " );

        # If v58+, get quota via doveadm command.
        if ( $CPVersion gt "11.58.0.0" ) {
            my $quotaline =
qx[ doveadm -f tab quota get -u $emailacctline\@$DOMAIN | grep 'Mailbox' | grep -v 'MESSAGE' ];
            if ( $quotaline =~ m/Error: User doesn't exist/ ) {
                print "[Quota cannot be determined]\n";
            }
            else {
                my ( $qused, $qlimit, $qpercent ) =
                  ( split( /\s+/, $quotaline ) )[ 2, 3, 4 ];
                if ( $qused == 0 ) {
                    $qused = 0;
                }
                else {
                    $qused = ( $qused / 1024 );
                }
                if ( $qlimit eq "-" ) {
                    $qlimit = "Unlimited";
                }
                else {
                    $qlimit = ( $qlimit / 1024 );
                }
                print "[Quota Used "
                  . $qused
                  . " MB of "
                  . $qlimit . " MB ("
                  . $qpercent . "%)]\n";
            }
        }
        else {
            print "\n";
        }

        # Check the passwd and shadow files to make sure an entry exists
        my $upasswdline;
        my $ushadowline;
        my $upasswdOK = 0;
        my $ushadowOK = 0;
        if ( -e ("$RealHome/etc/$DOMAIN/passwd") ) {
            open( UPASSWD, "$RealHome/etc/$DOMAIN/passwd" );
            my @UPASSWD = <UPASSWD>;
            close(UPASSWD);
            my $upasswdstring = "$emailacctline:x:";
            foreach $upasswdline (@UPASSWD) {
                chomp($upasswdline);
                if ( $upasswdline =~ m/^$upasswdstring/ ) {
                    $upasswdOK = 1;
                    last;
                }
            }
        }
        else {
            print RED
              "[WARN] - $RealHome/etc/$DOMAIN/passwd file is missing!\n";
            $upasswdOK = 0;
            next;
        }

        # Check for suspended from incoming email
        if ( -e ("$RealHome/etc/.$emailacctline\@$DOMAIN.suspended_incoming") )
        {
            print expand( RED "\t \t \\_ incoming email suspended\n" );
        }

        # Shadow file
        if ( -e ("$RealHome/etc/$DOMAIN/shadow") ) {
            open( USHADOW, "$RealHome/etc/$DOMAIN/shadow" );
            my @USHADOW = <USHADOW>;
            close(USHADOW);
            my $shadowstring = "$emailacctline:!!";
            foreach $ushadowline (@USHADOW) {
                chomp($ushadowline);
                if ( $ushadowline =~ m/^$emailacctline/ ) {
                    if ( $ushadowline =~ m/^$shadowstring/ ) {
                        print expand( RED "\t \t \\_ email login suspended\n" );
                    }
                    $ushadowOK = 1;
                    last;
                }
            }
        }
        else {
            print RED
              "[WARN] - $RealHome/etc/$DOMAIN/shadow file is missing!\n";
            $ushadowOK = 0;
            next;
        }
        if ( !($upasswdOK) ) {
            print expand( RED
"\t\t \\_ [WARN] - Missing passwd entry for $emailacctline\@$DOMAIN"
            );
            print "\n";
        }
        if ( !($ushadowOK) ) {
            print expand( RED
"\t\t \\_ [WARN] - Missing shadow entry for $emailacctline\@$DOMAIN"
            );
            print "\n";
        }

        # Check for .boxtrapperenable touch file - enabled if it exists.
        if ( -e ("$RealHome/etc/$DOMAIN/$emailacctline/.boxtrapperenable") ) {
            print expand( YELLOW "\t \t \\_ Spam Boxtrapper Enabled\n" );
        }

        # Check for mailbox_format.cpanel file. Display contents if it exists
        if (
            -e ("$RealHome/mail/$DOMAIN/$emailacctline/mailbox_format.cpanel") )
        {
            my $mbformat =
qx [ cat "$RealHome/mail/$DOMAIN/$emailacctline/mailbox_format.cpanel" ];
            chomp($mbformat);
            print expand(
                YELLOW "\t \t \\_ Account is using the $mbformat format.\n" );
        }

        # Check rcube.db for corruption
        if ( -e ("$RealHome/etc/$DOMAIN/$emailacctline.rcube.db") ) {
            print expand( CYAN
"\t\t \\_ Checking $RealHome/etc/$DOMAIN/$emailacctline.rcube.db for corruption: "
            );
            my $rcubechk =
              SQLiteDBChk("$RealHome/etc/$DOMAIN/$emailacctline.rcube.db");
            if ( $rcubechk =~ m/ok/ ) {
                print GREEN "OK\n";
            }
            else {
                print RED $rcubechk . "\n";
            }
        }

        # mail filters
        my $filtercnt = 0;
        my $ufilter;
        my @UFILTER;
        my @ufiltname;

        if ( -e ("$RealHome/etc/$DOMAIN/$emailacctline/filter") ) {
            open( FILTFILE, "$RealHome/etc/$DOMAIN/$emailacctline/filter" );
            my @UFILTER = <FILTFILE>;
            close(FILTFILE);
            foreach $ufilter (@UFILTER) {
                if (   substr( $ufilter, 0, 2 ) =~ m/# /
                    or substr( $ufilter, 0, 2 ) =~ m/#$/ )
                {
                    next;
                }
                if ( substr( $ufilter, 0, 1 ) eq "#" ) {
                    push( @ufiltname, substr( $ufilter, 1 ) );
                    $filtercnt++;
                }
            }
            if ( $filtercnt > 0 ) {
                print expand( YELLOW "\t \t \\_ has "
                      . $filtercnt
                      . " user level filters\n" );
                my $listfilt;
                foreach $listfilt (@ufiltname) {
                    chomp($listfilt);
                    print expand(
                        MAGENTA "\t\t\t \\_ Name: " . $listfilt . "\n" );
                }
            }
        }
    }
    smborder();

# Now let's get the MX record and make sure the A record for it points to this server.
    print "Checking MX records for $DOMAIN...\n";
    my @MXRecords = getMXrecord($DOMAIN);
    my $myline;
    my $skipMXchk = 0;
    foreach $myline (@MXRecords) {
        chomp($myline);
        if ( $myline eq "NONE" ) {
            $skipMXchk = 1;
            last;
        }
    }
    my $IsRemote = 0;
    my $MXRecord;
    my $Is_IP_OnServer;
    if ( !$skipMXchk ) {
        if (@MXRecords) {
            foreach $MXRecord (@MXRecords) {
                chomp($MXRecord);
                my $ARecordForMX;
                my @ARecordForMX = getArecords($MXRecord);
                foreach $ARecordForMX (@ARecordForMX) {
                    chomp($ARecordForMX);
                    my $IS_NAT = check_for_nat($ARecordForMX);
                    if ($IS_NAT) {    ## NAT IP ADDRESS RETURNED!
                        $Is_IP_OnServer = qx[ ip addr | grep '$IS_NAT' ];
                        if ($Is_IP_OnServer) {
                            print expand( YELLOW
"\t \\_ $MXRecord resolves to $ARecordForMX => $IS_NAT (Configured on this server)\n"
                            );

                            # Check reverse
                            my $ReverseOfMX = getptr($MXRecord);
                            if ( $ReverseOfMX eq $MXRecord ) {
                                print expand( GREEN
"\t\t \\_ [OK] - $ARecordForMX reverses back to the MX: $MXRecord\n"
                                );
                            }
                            elsif ( $ReverseOfMX eq $HOSTNAME ) {
                                print expand( GREEN
"\t\t \\_ [OK] - $ARecordForMX reverses back to the hostname: $HOSTNAME\n"
                                );
                            }
                            elsif ( $ReverseOfMX eq "mail.$MXRecord" ) {
                                print expand( GREEN
"\t\t \\_ [OK] - $ARecordForMX reverses back to: mail.$MXRecord\n"
                                );
                            }
                            else {
                                if ( $ReverseOfMX eq "" ) {
                                    $ReverseOfMX = "[NXDOMAIN]";
                                }
                                print expand( RED
"\t\t \\_ [WARN] - $ARecordForMX reverses back to: $ReverseOfMX\n"
                                );
                            }
                        }
                        else {
                            print expand( YELLOW
"\t \\_ $MXRecord resolves to $ARecordForMX (NOT configured on this server)\n"
                            );
                            $IsRemote = 1;
                        }
                    }
                    else {    ## NO NAT FOUND!
                        $Is_IP_OnServer = qx[ ip addr | grep '$ARecordForMX' ];
                        if ($Is_IP_OnServer) {
                            print expand( YELLOW
"\t \\_ $MXRecord resolves to $ARecordForMX (Configured on this server)\n"
                            );

                            # Check reverse
                            my $ReverseOfMX = getptr($MXRecord);
                            if ( $ReverseOfMX eq $MXRecord ) {
                                print expand( GREEN
"\t\t \\_ [OK] - $ARecordForMX reverses back to the MX: $MXRecord\n"
                                );
                            }
                            elsif ( $ReverseOfMX eq $HOSTNAME ) {
                                print expand( GREEN
"\t\t \\_ [OK] - $ARecordForMX reverses back to the hostname $HOSTNAME\n"
                                );
                            }
                            elsif ( $ReverseOfMX eq "mail.$MXRecord" ) {
                                print expand( GREEN
"\t\t \\_ [OK] - $ARecordForMX reverses back to mail.$MXRecord\n"
                                );
                            }
                            else {
                                if ( $ReverseOfMX eq "" ) {
                                    $ReverseOfMX = "[NXDOMAIN]";
                                }
                                print expand( RED
"\t\t \\_ [WARN] - $ARecordForMX reverses back to $ReverseOfMX\n"
                                );
                            }
                        }
                        else {
                            print expand( YELLOW
"\t \\_ $MXRecord resolves to $ARecordForMX (NOT configured on this server)\n"
                            );
                            $IsRemote = 1;
                        }
                    }
                }
            }
        }
    }
    else {
        print expand( CYAN "\t \\_ None\n" );
    }

# Depending on whether $IsRemote is true or false, we check if the domain is listed in
# /etc/localdomains or /etc/remotedomains
    smborder();
    my $IsInRemoteDomains = qx[ egrep -w '^$DOMAIN' /etc/remotedomains ];
    my $IsInLocalDomains  = qx[ egrep -w '^$DOMAIN' /etc/localdomains ];
    chomp($IsInRemoteDomains);
    chomp($IsInLocalDomains);
    print "Checking email routing (based on MX check above)...\n";
    if ($IsRemote) {

        if ($IsInRemoteDomains) {
            print expand( GREEN
                  "\t \\_ [OK] - $DOMAIN is listed in /etc/remotedomains\n" );
            $IsInLocalDomains = qx[ egrep -w '^$DOMAIN' /etc/localdomains ];
            if ($IsInLocalDomains) {
                print expand( RED
                      "\t \\_ [WARN] - $DOMAIN was found in /etc/localdomains\n"
                );
            }
        }
        else {
            print expand( RED
                  "\t \\_ [WARN] - $DOMAIN is missing from /etc/remotedomains\n"
            );
            if ($IsInLocalDomains) {
                print expand( RED
                      "\t \\_ [WARN] - $DOMAIN was found in /etc/localdomains\n"
                );
                print expand( YELLOW
"\t \\_ [NOTE] - OK if MX record is pointing to an external anti-spam service/gateway\n"
                );
            }
        }
    }
    else {    ## is local
        if ($IsInLocalDomains) {
            print expand( GREEN
                  "\t \\_ [OK] - $DOMAIN is listed in /etc/localdomains\n" );
            $IsInRemoteDomains = qx[ egrep -w '^$DOMAIN' /etc/remotedomains ];
            if ($IsInRemoteDomains) {
                print expand( RED
"\t \\_ [WARN] - $DOMAIN was found in /etc/remotedomains\n"
                );
            }
        }
        else {
            print expand( RED
                  "\t \\_ [WARN] - $DOMAIN is missing from /etc/localdomains\n"
            );
            if ($IsInRemoteDomains) {
                print expand( RED
"\t \\_ [WARN] - $DOMAIN was found in /etc/remotedomains\n"
                );
            }
        }
    }

    # Now list aliases (if any)
    my $emailfwd;
    my $fwdtype;
    my $listfwd;
    smborder();
    print "Aliases/Forwarders:\n";
    open( FORWARDERS, "/etc/valiases/$DOMAIN" );
    my @FWDS = <FORWARDERS>;
    close(FORWARDERS);

    if (@FWDS) {
        foreach $emailfwd (@FWDS) {
            chomp($emailfwd);
            if ( $emailfwd =~ m/: / ) { $fwdtype = "(normal forward/alias)"; }
            if ( $emailfwd =~ m/\*:/ ) {
                $fwdtype = "(deliver to $username main account)";
            }
            if ( $emailfwd =~ m/:fail:/ ) {
                $fwdtype = "(fail - bounce with message)";
            }
            if ( $emailfwd =~ m/:blackhole:/ ) {
                $fwdtype = "(blackhole - discard [not recommended])";
            }
            if ( $emailfwd =~ m/\|/ ) { $fwdtype = "(pipe to program)"; }
            if ( $emailfwd =~ m/autorespond/ ) {
                $fwdtype = "(auto responder)";
            }
            if ( $emailfwd =~ m/mailman\/mail/ ) {
                $fwdtype = "(mailman list)";
                ($listfwd) = ( split( /\s+/, $emailfwd ) )[0];
                $emailfwd = $listfwd;
            }
            print expand(
                YELLOW "\t \\_ " . $emailfwd . " " . $fwdtype . "\n" );
        }
    }
    else {
        print expand( CYAN "\t \\_ None\n" );
    }

    # get any system level filters (from /etc/vfilters/$DOMAIN file)
    my $gfilter;
    smborder();
    print "Global Level (system) Filters:\n";
    open( GFILTFILE, "/etc/vfilters/$DOMAIN" );
    my @GFILTER    = <GFILTFILE>;
    my $gfiltercnt = 0;
    my @gfiltname;
    close(GFILTFILE);

    if (@GFILTER) {
        foreach $gfilter (@GFILTER) {
            if (   substr( $gfilter, 0, 2 ) =~ m/# /
                or substr( $gfilter, 0, 2 ) =~ m/#$/ )
            {
                next;
            }
            if ( substr( $gfilter, 0, 1 ) eq "#" ) {
                push( @gfiltname, substr( $gfilter, 1 ) );
                $gfiltercnt++;
            }
        }
        print expand( CYAN "\t \t \\_ "
              . $DOMAIN . " has "
              . $gfiltercnt
              . " global level filters\n" );
        my $glistfilt;
        foreach $glistfilt (@gfiltname) {
            chomp($glistfilt);
            print expand( YELLOW "\t\t\t \\_ Name: " . $glistfilt . "\n" );
        }
    }
    else {
        print expand( CYAN "\t \\_ None\n" );
    }

    # Here we add the spf record and dkim record (if they exist).
    my $spf =
qx[ dig +tries=2 +time=5 \@208.67.222.222 $DOMAIN TXT +short | grep 'spf1' ];
    my $dkim =
qx[ dig +tries=2 +time=5 \@208.67.220.220 default._domainkey.$DOMAIN TXT +short ];
    my $dmarc =
      qx[ dig +tries=2 +time=5 \@208.67.222.222 _dmarc.$DOMAIN TXT +short ];
    print "Checking SPF Record For $DOMAIN\n";
    if ($spf) {
        print expand( YELLOW "\t \\_ " . $spf );
        if ( $spf =~ m/\+all/ ) {
            print expand( CYAN
"\t\t \\_ Pass All (Allow all email! Like not having any SPF at all)\n"
            );
        }
        if ( $spf =~ m/\-all/ ) {
            print expand( CYAN
"\t\t \\_ Hard Fail (Reject all email unless from ipv4/ipv6, mx or a)\n"
            );
        }
        if ( $spf =~ m/\~all/ ) {
            print expand( CYAN
"\t\t \\_ Soft Fail (Allow mail from anywhere, but mark as possible forgery) [DEFAULT]\n"
            );
        }
        if ( $spf =~ m/\?all/ ) {
            print expand( CYAN
"\t\t \\_ Neutral (No policy statement! Like not having any SPF at all)\n"
            );
        }
        print "\n";
    }
    else {
        print expand( YELLOW "\t \\_ None\n" );
    }
    print "Checking DKIM Record For default._domainkey.$DOMAIN\n";
    if ($dkim) {
        print expand( YELLOW "\t \\_ " . $dkim . "\n" );
    }
    else {
        print expand( YELLOW "\t \\_ None\n" );
    }
    print "Checking DMARC Record For _dmarc.$DOMAIN\n";
    if ($dmarc) {
        print expand( YELLOW "\t \\_ " . $dmarc . "\n" );
    }
    else {
        print expand( YELLOW "\t \\_ None\n" );
    }

    # Add MAX_EMAIL_PER_HOUR, MAX_DEFER_FAIL_PERCENTAGE, MAILBOX_FORMAT
    $MAILBOX_FORMAT            = $user_conf->{'MAILBOX_FORMAT'};
    $MAX_EMAIL_PER_HOUR        = $user_conf->{'MAX_EMAIL_PER_HOUR'};
    $MAX_DEFER_FAIL_PERCENTAGE = $user_conf->{'MAX_DEFER_FAIL_PERCENTAGE'};
    $MAXPOP                    = $user_conf->{'MAXPOP'};
    print WHITE "Max Mail Accounts " . CYAN $MAXPOP . "\n";
    print WHITE "Mailbox Format: " . CYAN ucfirst($MAILBOX_FORMAT) . "\n";
    print WHITE "Max Emails Per Hour: "
      . CYAN ucfirst($MAX_EMAIL_PER_HOUR) . "\n";
    print WHITE "Max Defer Fail %: "
      . CYAN ucfirst($MAX_DEFER_FAIL_PERCENTAGE) . "\n";

# Check here if send mail from dedicated IP is set and if /etc/mailips or /etc/mailhelo is
# referenced.
    my $SendFromDedicated =
      qx[ grep 'per_domain_mailips=1' /etc/exim.conf.localopts ];
    $SendFromDedicated = ($SendFromDedicated) ? "Yes" : "No";
    my $CustomHelo = qx[ grep 'custom_mailhelo=1' /etc/exim.conf.localopts ];
    $CustomHelo = ($CustomHelo) ? "Yes" : "No";
    my $CustomMailIP = qx[ grep 'custom_mailips=1' /etc/exim.conf.localopts ];
    $CustomMailIP = ($CustomMailIP) ? "Yes" : "No";
    my $CustomMailIPText = "";

    if ( $CustomMailIP eq "Yes" ) {
        $CustomMailIPText = qx[ egrep '^$MAINDOMAIN' /etc/mailips ];
        chomp($CustomMailIPText);
    }
    my $CustomHeloText = "";
    if ( $CustomHelo eq "Yes" ) {
        $CustomHeloText = qx[ egrep '^$MAINDOMAIN' /etc/mailhelo ];
        chomp($CustomHeloText);
    }
    print WHITE "Send from dedicated IP: " . CYAN $SendFromDedicated . "\n";
    print WHITE "Using Custom HELO (/etc/mailhelo): "
      . CYAN $CustomHelo . " "
      . YELLOW $CustomHeloText . "\n";
    print WHITE "Using Custom IP (/etc/mailips): "
      . CYAN $CustomMailIP . " "
      . YELLOW $CustomMailIPText . "\n";
    border();
}

sub getMXrecord {
    my $tcDomain = $_[0];
    my $rr;
    my @NEWMX;
    my $res = Net::DNS::Resolver->new;
    my @mx = mx( $res, $tcDomain );
    if (@mx) {
        foreach $rr (@mx) {
            push( @NEWMX, $rr->exchange );
        }
        return @NEWMX;
    }
    else {
        return "NONE";
    }
}

sub getptr() {
    my $ip = $_[0];
    chomp($ip);
    my $ipaddr = inet_aton($ip);
    my $ptrname = gethostbyaddr( $ipaddr, AF_INET );
    return $ptrname;
}

sub getArecords {
    my $tcDomain  = $_[0];
    my @addresses = gethostbyname($tcDomain);
    @addresses = map { inet_ntoa($_) } @addresses[ 4 .. $#addresses ];
    return @addresses;
}

sub scan {
    my $URL =
"https://raw.githubusercontent.com/cPanelPeter/infection_scanner/master/strings.txt";
    my @DEFINITIONS = qx[ curl -s $URL ];
    my $StringCnt   = @DEFINITIONS;

    # Need to define and use $RealHome if $HOMEDIR doesn't exist!!!
    open( PASSWD, "/etc/passwd" );
    @PASSWDS = <PASSWD>;
    close(PASSWD);
    foreach $passline (@PASSWDS) {
        chomp($passline);
        if ( $passline =~ m/\b$username\b/ ) {
            ($UID)       = ( split( /:/, $passline ) )[2];
            ($GID)       = ( split( /:/, $passline ) )[3];
            ($RealHome)  = ( split( /:/, $passline ) )[5];
            ($RealShell) = ( split( /:/, $passline ) )[6];
            last;
        }
    }

    print "Scanning $RealHome for ($StringCnt) known infections:\n";
    my @SEARCHSTRING    = sort(@DEFINITIONS);
    my @FOUND           = undef;
    my $SOMETHING_FOUND = 0;
    my $SEARCHSTRING;
    my ( $sec, $min, $hour, $mday, $mon, $year );
    my $scanstarttime = Time::Piece->new;

    print "Scan started on $scanstarttime\n";

    foreach $SEARCHSTRING (@SEARCHSTRING) {
        spin();
        chomp($SEARCHSTRING);
        my $SCAN =
qx[ grep -srIl --exclude-dir=www --exclude-dir=mail --exclude-dir=tmp --exclude=*.png --exclude=*.svg --exclude-dir=access-logs -w "$SEARCHSTRING" $RealHome/* ];

        chomp($SCAN);
        if ($SCAN) {
            $SOMETHING_FOUND = 1;
            $SEARCHSTRING =~ s/\\//g;
            print YELLOW "\n\n\bThe phrase "
              . CYAN
              . $SEARCHSTRING
              . YELLOW
              . " was found in file(s)\n";
            print GREEN
"==================================================================\n";
            print RED "$SCAN\n";
        }
    }
    if ( $SOMETHING_FOUND == 0 ) {
        print GREEN "\bNothing suspicious found!\n";
    }
    print "\n";
    my $scanendtime = Time::Piece->new;
    print "Scan completed on $scanendtime\n";
    my $scantimediff = ( $scanendtime - $scanstarttime );
    print "Elapsed Time: ", $scantimediff->pretty, "\n";
    print "</c>\n" unless ($nocodeblock);
}

sub spin {
    my %spinner = ( '|' => '/', '/' => '-', '-' => '\\', '\\' => '|' );
    $spincounter = ( !defined $spincounter ) ? '|' : $spinner{$spincounter};
    print STDERR "\b$spincounter";
}

sub getSSLProvider {
    my $RetVal = "";
    my $SSLmodule =
qx[ whmapi1 get_autossl_providers | grep -A1 'enabled: 1' | grep 'module_name' ];
    ($RetVal) = ( split( /:/, $SSLmodule ) )[1];
    chomp($RetVal);
    if ( $RetVal eq "" ) { $RetVal = "Disabled"; }
    return $RetVal;
}

sub ChkForIntegration {
    my @ILINKS =
      qx[ whmapi1 list_integration_links user=$username | grep 'app:' ];
    my $cnt = @ILINKS;
    if ( $cnt > 0 ) {
        print YELLOW "[NOTE] * Integration links found in " . GREEN
          . "/var/cpanel/integration/dynamicui/$username\n";
    }
}

sub dispSSLdata {
    my $tcDomain = $_[0];
    my $CNloc    = index( $sslsubject, "CN=" );
    my $CN       = substr( $sslsubject, $CNloc );
    my ( $domain, $crap ) = ( split( /\//, $CN ) )[0];
    $domain = substr( $domain, 3 );
    chomp($domain);
    chomp($startdate);
    chomp($expiredate);
    ($startdate)  = ( split( /=/, $startdate ) )[1];
    ($expiredate) = ( split( /=/, $expiredate ) )[1];
    my $isExpired;

    if ( $noDateManip == 0 ) {
        my $unix_time = UnixDate( ParseDate($expiredate), "%s" );
        my $time_now = qx[ date -u ];
        chomp($time_now);
        my $unix_time_now = UnixDate( ParseDate($time_now), "%s" );
        $isExpired = GREEN "[VALID]";
        if ( $unix_time_now > $unix_time ) {
            $isExpired = RED "[EXPIRED]";
        }
    }
    print YELLOW . $domain . "\n";
    print expand( WHITE "\t \\_ Not Before: " . GREEN . $startdate . "\n" );
    print expand( WHITE "\t \\_ Not After : "
          . GREEN
          . $expiredate . " "
          . $isExpired
          . "\n" );
    if ($isSelfSigned) {
        print expand(
            RED "\t \\_ [WARN] " . WHITE "- Self-Signed Certificate\n" );
    }
    else {
        # Get Issuer and display it.
        my $SSLIssuer =
qx[ openssl x509 -in "$sslsyscertdir/$tcDomain/certificates" -issuer -noout ];
        my $Oloc = index( $SSLIssuer, "O=" );
        my $O = substr( $SSLIssuer, $Oloc );
        my ( $SSLIssuer, $crap ) = ( split( /\//, $O ) )[0];
        $SSLIssuer = substr( $SSLIssuer, 2 );
        chomp($SSLIssuer);
        print expand(
            GREEN "\t \\_ [CA SIGNED] " . WHITE "Issued by: $SSLIssuer\n" );
    }
    my $OCSPstatus =
qx[ openssl s_client -connect $tcDomain:443 -servername $tcDomain -status <<<quit 2>&1 | egrep 'Cert Status:' ];
    if ($OCSPstatus) {
        print expand( BOLD CYAN "\t \\_ OCSP: "
              . BOLD MAGENTA substr( $OCSPstatus, 17 )
              . "\n" );
    }
}

sub oldlistssls {
    my $sslcertdir    = "$RealHome/ssl/certs";
    my $sslsyscertdir = "/var/cpanel/ssl/installed/certs";
    my @certs;
    my $cert;
    my $sslsubject;
    my $startdate;
    my $expiredate;
    if ( -e ("$sslcertdir") ) {
        print WHITE "SSL Certificates installed under "
          . CYAN $MAINDOMAIN
          . WHITE " ("
          . GREEN $username
          . WHITE ")\n";
        opendir( ssldir, "$sslcertdir" );
        my @certs = readdir(ssldir);
        closedir(ssldir);
        foreach $cert (@certs) {
            my $SSLNotInstalled = 0;
            chomp($cert);
            if (   $cert eq "."
                or $cert eq ".."
                or ( substr( $cert, -4 ) ne '.crt' ) )
            {
                next;
            }
            if ( !( -e ("$sslsyscertdir/$cert") ) ) {
                next;
            }
            $sslsubject =
              qx[ openssl x509 -in "$sslcertdir/$cert" -subject -noout ];
            my $CNloc = index( $sslsubject, "CN=" );
            my $CN = substr( $sslsubject, $CNloc );
            my ( $domain, $crap ) = ( split( /\//, $CN ) )[0];
            $domain = substr( $domain, 3 );
            chomp($domain);
            $startdate =
              qx[ openssl x509 -in "$sslcertdir/$cert" -startdate -noout ];
            $expiredate =
              qx[ openssl x509 -in "$sslcertdir/$cert" -enddate -noout ];
            chomp($startdate);
            chomp($expiredate);
            ($startdate)  = ( split( /=/, $startdate ) )[1];
            ($expiredate) = ( split( /=/, $expiredate ) )[1];
            my $isExpired;

            if ( $noDateManip == 0 ) {
                my $unix_time = UnixDate( ParseDate($expiredate), "%s" );
                my $time_now = qx[ date -u ];
                chomp($time_now);
                my $unix_time_now = UnixDate( ParseDate($time_now), "%s" );
                $isExpired = GREEN "[VALID]";
                if ( $unix_time_now > $unix_time ) {
                    $isExpired = RED "[EXPIRED]";
                }
            }
            print YELLOW . $domain . MAGENTA " (" . $cert . ")\n";
            print expand(
                WHITE "\t \\_ Not Before: " . GREEN . $startdate . "\n" );
            print expand( WHITE "\t \\_ Not After : "
                  . GREEN
                  . $expiredate . " "
                  . $isExpired
                  . "\n" );

            # Check if self-signed
            my $isSelfSigned =
qx[ openssl verify "$sslcertdir/$cert" | grep 'self signed certificate' ];
            if ($isSelfSigned) {
                print expand( RED "\t \\_ [WARN] "
                      . WHITE "- Self-Signed Certificate\n" );
            }
            else {
                # Get Issuer and display it.
                my $SSLIssuer =
                  qx[ openssl x509 -in "$sslcertdir/$cert" -issuer -noout ];
                my $Oloc = index( $SSLIssuer, "O=" );
                my $O = substr( $SSLIssuer, $Oloc );
                my ( $SSLIssuer, $crap ) = ( split( /\//, $O ) )[0];
                $SSLIssuer = substr( $SSLIssuer, 2 );
                chomp($SSLIssuer);
                print expand( GREEN "\t \\_ [CA SIGNED] "
                      . WHITE "Issued by: $SSLIssuer\n" );
            }

            # List SAN's
            print WHITE
"This certificate is protecting the following Subject Alternative Names:\n";
            my $SAN;
            my @getSANS =
qx[ openssl x509 -in "$sslcertdir/$cert" -noout -text | grep -oP '(?<=DNS:)[a-z0-9.-]+' ];
            foreach $SAN (@getSANS) {
                chomp($SAN);
                print expand( YELLOW "\t \\_ " . CYAN $SAN . "\n" );
            }
        }
    }
    else {
        print WHITE "No SSL Certificates found for "
          . CYAN $MAINDOMAIN
          . WHITE " ("
          . GREEN $username
          . WHITE ")\n";
    }

# Check for pending AutoSSL orders here (uses whmapi1 get_autossl_pending_queue (62.0.26+ only)
    if ( $CPVersion gt "11.60.0.26" ) {
        if ( $SSLProvider eq " cPanel" ) {
            print "\nChecking for pending AutoSSL orders: \n";
            my $SSL_PENDING =
qx[ whmapi1 get_autossl_pending_queue | grep -B3 'user: $username' ];
            if ($SSL_PENDING) {
                my $NEW_SSL_PENDING;
                ( $NEW_SSL_PENDING = $SSL_PENDING ) =~
s/order_item_id: /order_item_id: https:\/\/manage2.cpanel.net\/certificate.cgi\?oii=/g;
                $SSL_PENDING = $NEW_SSL_PENDING;
                print expand( GREEN "\t \\_ \n" );
                print GREEN "$SSL_PENDING";
            }
            else {
                print expand( GREEN "\t \\_ None" );
            }
            print "\n";
        }
    }

    # Check for CAA records here.
    print "Checking for CAA records: \n";
    my @HasCAA = qx[ dig +tries=2 +time=5 $MAINDOMAIN caa +short ];
    my $CAARecord;
    if (@HasCAA) {
        print YELLOW "[NOTE] * CAA records were found for $MAINDOMAIN\n";
        print GREEN
          "SSL Certificates can only be issued from the following CA's:\n";
        foreach $CAARecord (@HasCAA) {
            chomp($CAARecord);
            print expand( CYAN "\t \\_ $CAARecord\n" );
        }
    }
    else {
        print expand( GREEN "\t \\_ None\n" );
    }
    border();
}

sub isUserReserved {
    my $lcUser = $_[0];
    my $UserList;
    my @UserList =
qx[ /usr/local/cpanel/3rdparty/bin/perl -MCpanel::Validate::Username -MData::Dumper -e 'print Dumper(Cpanel::Validate::Username::list_reserved_usernames());' ];
    foreach $UserList (@UserList) {
        chomp($UserList);
        if ( $UserList =~ $lcUser ) {
            return 1;
        }
    }
}

sub SQLiteDBChk {
    my $lcDB = $_[0];
    $result = "";
    my $dbh =
      DBI->connect( "dbi:SQLite:dbname=$lcDB", "", "",
        { RaiseError => 1, HandleError => \&handle_error },
      ) or die $DBI::errstr;
    my $sth = $dbh->prepare("pragma quick_check");
    if ($result) {
        $result = "Corrupted";
    }
    else {
        $sth->execute() or die $DBI::errstr;
        my @row;
        while ( @row = $sth->fetchrow_array() ) {
            $result = "@row";
        }
        $sth->finish();
        $dbh->disconnect();
    }
    return $result;
}

sub handle_error {
    my $error = shift;
    $result = 1;
    return $result;
}

sub checkperms {
    if ( !-e ("$RealHome") ) {
        print RED"[WARN] - $RealHome directory is missing!";
    }
    else {
        my $statmode = ( stat($RealHome) )[2] & 07777;
        $statmode = sprintf "%lo", $statmode;
        if ( $statmode != 711 ) {
            print RED
              "[WARN] - $RealHome permissions are not 711 [$statmode]\n";
        }
    }
    my $fuid       = ( stat "$RealHome" )[4];
    my $fgid       = ( stat "$RealHome" )[5];
    my $fileowner  = ( getpwuid $fuid )[0];
    my $groupowner = ( getgrgid $fgid )[0];
    if ( $fileowner ne $username or $groupowner ne $username ) {
        print RED
"[WARN] - Incorrect ownership/group for $RealHome [$fileowner:$groupowner]";
    }

    if ( !-e ("$RealHome/public_html") ) {
        print RED"[WARN] - $RealHome/public_html directory is missing!";
    }
    else {
        my $statmode = ( stat("$RealHome/public_html") )[2] & 07777;
        $statmode = sprintf "%lo", $statmode;
        if ( $statmode != 750 ) {
            print RED
"[WARN] - $RealHome/public_html permissions are not 750 [$statmode]";
        }
    }
    my $fuid       = ( stat "$RealHome/public_html" )[4];
    my $fgid       = ( stat "$RealHome/public_html" )[5];
    my $fileowner  = ( getpwuid $fuid )[0];
    my $groupowner = ( getgrgid $fgid )[0];
    if ( $fileowner ne $username
        or ( $groupowner ne $username ) and ( $groupowner ne "nobody" ) )
    {
        print RED
"[WARN] - Incorrect ownership/group for $RealHome/public_html [$fileowner:$groupowner]";
    }

    if ( !-e ("$RealHome/etc") ) {
        print RED"[WARN] - $RealHome/etc directory is missing!";
    }
    else {
        my $statmode = ( stat("$RealHome/etc") )[2] & 07777;
        $statmode = sprintf "%lo", $statmode;
        if ( $statmode != 750 ) {
            print RED
              "[WARN] - $RealHome/etc permissions are not 750 [$statmode]";
        }
    }
    my $fuid       = ( stat "$RealHome/etc" )[4];
    my $fgid       = ( stat "$RealHome/etc" )[5];
    my $fileowner  = ( getpwuid $fuid )[0];
    my $groupowner = ( getgrgid $fgid )[0];
    if ( $fileowner ne $username or $groupowner ne "mail" ) {
        print RED
"[WARN] - Incorrect ownership/group for $RealHome/etc [$fileowner:$groupowner] Default: user:mail";
    }

    if ( !-e ("$RealHome/mail") ) {
        print RED"[WARN] - $RealHome/mail folder is missing!";
    }
    else {
        my $statmode = ( stat("$RealHome/mail") )[2] & 07777;
        $statmode = sprintf "%lo", $statmode;
        if ( $statmode != 751 ) {
            print RED
              "[WARN] - $RealHome/mail permissions are not 751 [$statmode]";
        }
    }
    my $fuid       = ( stat "$RealHome/mail" )[4];
    my $fgid       = ( stat "$RealHome/mail" )[5];
    my $fileowner  = ( getpwuid $fuid )[0];
    my $groupowner = ( getgrgid $fgid )[0];
    if ( $fileowner ne $username or $groupowner ne $username ) {
        print RED
"[WARN] - Incorrect ownership/group for $RealHome/mail [$fileowner:$groupowner]";
    }
}
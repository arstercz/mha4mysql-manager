package MHA::Extra;

our $VERSION = '0.1';

1;

package MHA::Extra::Config;

use strict;
use warnings;
use Carp;

sub new {
  my ($class, $filename) = @_;
  bless {
    file    => $filename,
    servers => _load_config($filename),
    },
    __PACKAGE__;
}

sub lookup {
  my ($self, $ip, $port) = @_;
  return _lookup( $self->{servers}, $ip, $port );
}

sub is_empty {
  my ($self) = @_;
  return @{ $self->{servers} } == 0;
}

sub _lookup {
  my ($servers, $ip, $port) = @_;
  for my $s ( @{$servers} ) {
    if ( $s->{ip} eq $ip && $s->{port} eq $port ) {
      return $s;
    }
  }
}

sub _load_config {
  my ($file) = @_;
  my @lines = ();
  if ( open my $fh, '<', $file ) {
    @lines = <$fh>;
    chomp(@lines);
    close $fh;
  }
  return _parse( \@lines );
}

sub _parse {
  my ($lines) = @_;

  my %global = ();
  my @lookup = ();

  my @block       = ();
  my %setting     = ();
  my $ctx         = "";
  my $i           = 0;
  my %seen_server = ();
  my %seen_vip    = ();
  my %seen_rip    = ();
  for ( @{$lines} ) {
    $i++;
    next if /^\s*(#.*)?$/;    # blank line
    s/#.*$|\s+$//;                 # trim comment or postfix space

    # default setting
    if (/^(\w+)\s+([^#]*)/) {
      $global{$1} = $2;
      $ctx = 'global';
    }

    # servers line
    elsif (/^\d/) {
      if ( $ctx && $ctx eq "setting" ) {    # finish a group
        for (@block) {
          $_ = { %setting, %{$_} };         # ip port won't be overwritten
        }
        push @lookup, @block;
        @block   = ();
        %setting = ();
      }

      $ctx = 'server';
      my @servers = /(\d+\.\d+\.\d+\.\d+:\d+)/g;
      for (@servers) {
        my ( $ip, $port ) = split /:/;
        push @{ $seen_server{"$ip:$port"} }, $i;
        push @{ $seen_rip{$ip} }, $i;
        push @block, { ip => $ip, port => $port };
      }
    }

    # server settings
    elsif (/^\s+\w/) {
      $ctx = 'setting';
      if ( my ( $k, $v ) = /^\s+(\w+)\s+([^#]+)/ ) {
        push( @{ $seen_vip{$v} }, $i ) if $k eq "vip";
        if ( $k eq "proxysql" ) {
          $setting{$k} = _proxysql_parse($v);
        }
        elsif ($k eq "consul_servers") {
          $setting{$k} = _consul_parse($v);
        }
        else {
          $setting{$k} = $v;
        }
      }
    }
  }

  # wrap up
  if (@block) {
    for (@block) {
      $_ = { %setting, %{$_} };    # ip port won't be overwritten
    }
    push @lookup, @block;
  }

  for my $server (@lookup) {
    for my $k ( keys %global ) {
      $server->{$k} = $global{$k} unless defined $server->{$k};
    }
  }

  while ( my ( $k, $v ) = each %seen_server ) {
    croak "detected server duplication $k at lines @{$v}" if @{$v} > 1;
  }
  while ( my ( $k, $v ) = each %seen_vip ) {
    croak "detected vip duplication $k at lines @{$v}" if @{$v} > 1;
  }
  for my $vip ( keys %seen_vip ) {
    if ( $seen_rip{$vip} ) {
      croak
"detected vip $vip at line @{$seen_vip{$vip}} duplicates rip at line @{$seen_rip{$vip}}";
    }
  }
  for my $s (@lookup) {
    if ($s->{mode} ne 'none'
        && $s->{mode} ne 'vip'
        && $s->{mode} ne 'dns'
        && $s->{mode} ne 'proxysql'
       )
    {
      croak "\nError - the mode must be none, vip, dns or proxysql.";
    }

    my $server = "$s->{ip}:$s->{port}";
    croak "\nError - vip is not configured for $server at line @{$seen_server{$server}}"
      if ($s->{mode} eq 'vip' && !$s->{vip});
    croak "\nError - consul_name or consul_servers are not configured for $server at line @{$seen_server{$server}} when mode is dns"
      if ($s->{mode} eq 'dns' && !$s->{consul_name} && !$s->{consul_servers});
    croak "\nError - proxysql is not configured for $server at line @{$seen_server{$server}}"
      if ($s->{mode} eq 'proxysql' && !$s->{proxysql});

    croak
"block_user and block_host must be both or none for $server at line @{$seen_server{$server}}"
      unless ( $s->{block_user} && $s->{block_host} )
           || ( !$s->{block_user} && !$s->{block_host} );
  }

  return \@lookup;
}

sub _proxysql_parse {
  my $list = shift;
  my @proxysql = ();
  my $n = 0;
  # such as: admin:admin@10.0.21.5:6032:r1:w2,admin:admin@10.0.21.7:6032:r1:w2
  foreach (split(/,/, $list)) {
    if (/(\S+?):(\S+?)\@(\S+?):(\d+):w(\d+):r(\d+)/) {
      $proxysql[$n]->{user} = $1;
      $proxysql[$n]->{pass} = $2;
      $proxysql[$n]->{ip}   = $3;
      $proxysql[$n]->{port} = $4;
      $proxysql[$n]->{wgroup} = $5;
      $proxysql[$n]->{rgroup} = $6;
      $n++;
    }
  }
  return \@proxysql;
}

sub _consul_parse {
  my $list = shift;
  # such as: 10.1.1.2,10.1.1.3,10.1.1.4
  my @servers = split(/,\s*/, $list);

  return \@servers;
}

1;

package MHA::Extra::DBHelper;

use base 'MHA::DBHelper';

use strict;
use warnings;
use Carp;

use constant Get_Privileges_SQL => "SHOW GRANTS";
use constant Select_User_Regexp_SQL =>
"SELECT user, host, password FROM mysql.user WHERE user REGEXP ? AND host REGEXP ?";

# for MySQL 5.7 or above version
use constant Select_User_Regexp_New_SQL =>
"SELECT user, host, authentication_string AS password FROM mysql.user WHERE user REGEXP ? AND host REGEXP ?";
use constant Get_Version_SQL => "SELECT LEFT(VERSION(), 3) AS Value";

use constant Set_Password_SQL => "SET PASSWORD FOR ?\@? = ?";
use constant Granted_Privileges =>
  '^GRANT ([A-Z, ]+) ON (`\\w+`|\\*)\\.\\* TO';    # poor match on db
use constant Old_Password_Length          => 16;
use constant Blocked_Empty_Password       => '?' x 41;
use constant Blocked_Old_Password_Head    => '~' x 25;
use constant Blocked_New_Password_Regexp  => qr/^[0-9a-fA-F]{40}\*$/o;
use constant Released_New_Password_Regexp => qr/^\*[0-9a-fA-F]{40}$/o;
use constant Set_Rpl_Semi_Sync_Master_OFF => "SET GLOBAL rpl_semi_sync_master_enabled = OFF";
use constant Set_Rpl_Semi_Sync_Master_ON  => "SET GLOBAL rpl_semi_sync_master_enabled = ON";
use constant Set_Rpl_Semi_Sync_Master_Timeout => "SET GLOBAL rpl_semi_sync_master_timeout = 2000";
use constant Set_Rpl_Semi_Sync_Slave_OFF  => "SET GLOBAL rpl_semi_sync_slave_enabled = OFF";
use constant Set_Rpl_Semi_Sync_Slave_On   => "SET GLOBAL rpl_semi_sync_slave_enabled = ON";
use constant Get_Event_Scheduler_SQL      => 
"SELECT EVENT_NAME, EVENT_SCHEMA, STATUS FROM information_schema.EVENTS";
use constant Set_Event_Scheduler_ON       => "SET GLOBAL event_scheduler = ON";
use constant Set_Event_Scheduler_OFF      => "SET GLOBAL event_scheduler = OFF";
use constant Enable_Event_Scheduler       => "ALTER EVENT %s ENABLE";
use constant Disable_Event_Scheduler      => "ALTER EVENT %s DISABLE";

sub new {
  my ($class) = @_;
  bless {}, __PACKAGE__;
}

sub _get_variable {
  my $dbh = shift;
  my $query = shift;
  my $sth = $dbh->prepare($query);
  $sth->execute();
  my $href = $sth->fetchrow_hashref;
  return $href->{Value} || 5.5;
}

sub _get_version {
  my $dbh  = shift;
  my $value = _get_variable($dbh, Get_Version_SQL);
  return $value;
}

# see http://code.openark.org/blog/mysql/blocking-user-accounts
sub _blocked_password {
  my $password = shift;
  if ( $password eq '' ) {
    return Blocked_Empty_Password;
  }
  elsif ( length($password) == Old_Password_Length ) {
    return Blocked_Old_Password_Head . $password;
  }
  elsif ( $password =~ Released_New_Password_Regexp ) {
    return join( "", reverse( split //, $password ) );
  }
  else {
    return;
  }
}

sub _released_password {
  my $password = shift;
  if ( $password eq Blocked_Empty_Password ) {
    return '';
  }
  elsif ( index( $password, Blocked_Old_Password_Head ) == 0 ) {
    return substr( $password, length(Blocked_Old_Password_Head) );
  }
  elsif ( $password =~ Blocked_New_Password_Regexp ) {
    return join( "", reverse( split //, $password ) );
  }
  else {
    return;
  }
}

sub _block_release_user_by_regexp {
  my ( $dbh, $user, $host, $block ) = @_;
  #my $users_to_block = $dbh->selectall_arrayref( Select_User_Regexp_SQL, { Slice => {} },
  #$user, $host );
  my $users_to_block = do {
    if ( _get_version($dbh) >= 5.7 ) {
      $dbh->selectall_arrayref( Select_User_Regexp_New_SQL, { Slice => {} },
            $user, $host );
    }
    else {
      $dbh->selectall_arrayref( Select_User_Regexp_SQL, { Slice => {} },
            $user, $host );
    }
  };
  my $failure = 0;
  for my $u ( @{$users_to_block} ) {
    my $password =
      $block
      ? _blocked_password( $u->{password} )
      : _released_password( $u->{password} );
    if ( defined $password ) {
      my $ret =
        $dbh->do( Set_Password_SQL, undef, $u->{user}, $u->{host}, $password );
      unless ( $ret eq "0E0" ) {
        $failure++;
      }
    }
  }
  return $failure;
}

sub block_user_regexp {
  my ( $self, $user, $host ) = @_;
  return _block_release_user_by_regexp( $self->{dbh}, $user, $host, 1 );
}

sub release_user_regexp {
  my ( $self, $user, $host ) = @_;
  return _block_release_user_by_regexp( $self->{dbh}, $user, $host, 0 );
}

sub rpl_semi_orig_master_set {
  my $self = shift;
  my $status = $self->show_variable("rpl_semi_sync_master_enabled") || '';
  if ($status eq "ON") {
    $self->execute(Set_Rpl_Semi_Sync_Master_OFF);
    $self->execute(Set_Rpl_Semi_Sync_Slave_On);
  }
}

sub rpl_semi_new_master_set {
  my $self = shift;
  my $status = $self->show_variable("rpl_semi_sync_slave_enabled") || '';
  if ($status eq "ON") {
    $self->execute(Set_Rpl_Semi_Sync_Slave_OFF);
    $self->execute(Set_Rpl_Semi_Sync_Master_ON);
    $self->execute(Set_Rpl_Semi_Sync_Master_Timeout);
  }
}

sub _get_event_info {
  my $dbh  = shift;
  my %events;
  my $sth = $dbh->selectall_arrayref(Get_Event_Scheduler_SQL);
  foreach my $k (@$sth) {
    my ($name, $schema, $status) = @$k;
    if ($name && $schema) {
      $events{"$schema.$name"} = $status;
    }
  }
  return %events;
}

sub set_event_scheduler_on {
  my $self = shift;
  my $status = $self->show_variable("event_scheduler") || '';
  if ($status eq "OFF") {
    $self->execute(Set_Event_Scheduler_ON);
    my %events = _get_event_info($self->{dbh});
    foreach my $k (keys %events) {
      if ($events{$k} =~ /DISABLED/i) {
        my $event_sql = sprintf(Enable_Event_Scheduler, $k);
        $self->execute($event_sql);
      }
    }
  }
}

sub set_event_scheduler_off {
  my $self = shift;
  my $status = $self->show_variable("event_scheduler") || '';
  if ($status eq "ON") {
    $self->execute(Set_Event_Scheduler_OFF);
    my %events = _get_event_info($self->{dbh});
    foreach my $k (keys %events) {
      if ($events{$k} =~ /ENABLED/i) {
        my $event_sql = sprintf(Disable_Event_Scheduler, $k);
        $self->execute($event_sql);
      }
    }
  }
}

1;

package MHA::Extra::IpHelper;

# helps to manipulate VIP on target host

use strict;
use warnings;
use Carp;

sub new {
  my ( $class, %args ) = @_;
  croak "missing host to check against" unless $args{host};
  my $self = {};
  bless $self, $class;
  $self->{host}  = $args{host};
  $self->{port}  = $args{port} || 22;
  $self->{user}  = $args{user} || 'root';
  $self->{option}= $args{option};

  return $self;
}

# see perlsec
sub _safe_qx {
  my (@cmd) = @_;
  use English '-no_match_vars';
  my $pid;
  croak "Can't fork: $!" unless defined( $pid = open( KID, "-|" ) );
  if ($pid) {    # parent
    if (wantarray) {
      my @output = <KID>;
      close KID;
      return @output;
    }
    else {
      local $/;    # slurp mode
      my $output = <KID>;
      close KID;
      return $output;
    }
  }
  else {
    my @temp     = ( $EUID, $EGID );
    my $orig_uid = $UID;
    my $orig_gid = $GID;
    $EUID = $UID;
    $EGID = $GID;

    # Drop privileges
    $UID = $orig_uid;
    $GID = $orig_gid;

    # Make sure privs are really gone
    ( $EUID, $EGID ) = @temp;
    die "Can’t drop privileges"
      unless $UID == $EUID && $GID eq $EGID;
    $ENV{PATH} = "/bin:/usr/bin";    # Minimal PATH.
         # Consider sanitizing the environment even more.
    exec @cmd
      or die "can’t exec m$cmd[0]: $!";
  }
}

sub ssh_cmd {
  my ( $self, $cmd ) = @_;
  $self->{user} ||= 'root';
  $self->{port} ||= 22;
  my @cmd = ();
  push @cmd, 'ssh';
  push @cmd, split(/\s/, $self->{option}) if defined $self->{option};
  push @cmd, '-p', $self->{port};
  push @cmd, '-l', $self->{user};
  push @cmd, $self->{host};
  push @cmd, $cmd;
  return @cmd;
}

sub run_ssh_cmd {
  my ( $self, $cmd ) = @_;
  my @cmd = $self->ssh_cmd($cmd);
  return _safe_qx(@cmd);
}

sub assert_status {
  my ( $high, $low ) = get_run_status();
  if ( $high || $low ) {
    croak "command error $high:$low";
  }
}

sub get_run_status {
  return ( ( $? >> 8 ), ( $? & 0xff ) );    # high, low
}

sub get_ipaddr {
  my ($self) = @_;
  my $sudo = $self->{user} ne 'root' ? 'sudo' : '';
  chomp( my @ipaddr = $self->run_ssh_cmd("$sudo /sbin/ip addr") );
  assert_status();
  return \@ipaddr;
}

sub parse_ipaddr {
  my $output = shift;
  my %intf   = ();
  my $name;
  for ( @{$output} ) {
    if (/^\d+: (\S+): <[^,]+(?:,[^,]+)*> mtu \d+ qdisc \w+/) {
      $name = $1;
      $name =~ s/\@.*//g if $name =~ /\@/;
    }
    elsif (/^\s+link\/(\w+) (\S+) brd (\S+)/) {
      $intf{$name}{'link'} = { type => $1, mac => $2, brd => $3 };
    }
    elsif (/^\s+inet ([\d.]+)\/(\d+) (?:brd ([\d.]+))?/) {
      push @{ $intf{$name}{inet} },
        { ip => $1, bits => $2, ( $3 ? ( brd => $3 ) : () ) };
    }
    elsif (/^\w+inet6 ([\d:]+)\/(\d+)/) {
      push @{ $intf{$name}{inet6} }, { ip => $1, bits => $2 };
    }
  }
  return \%intf;
}

sub _get_numeric_ipv4 {
  my @parts = split /\./, shift;
  return ( $parts[0] << 24 ) + ( $parts[1] << 16 ) + ( $parts[2] << 8 ) +
    $parts[3];
}

sub _find_dev {
  my ( $intf, $vip ) = @_;
  for my $dev ( keys %{$intf} ) {
    my $inet = $intf->{$dev}{inet} or next;
    for my $addr ( @{$inet} ) {
      my $m   = ~( ( 1 << ( 32 - $addr->{bits} ) ) - 1 );
      my $ip1 = _get_numeric_ipv4( $addr->{ip} );
      my $ip2 = _get_numeric_ipv4($vip);
      if ( ( $ip1 & $m ) == ( $ip2 & $m ) ) {
        return ( $vip, $addr->{bits}, $dev );
      }
    }
  }
  return;
}

# is vip configured?
sub _check_vip {
  my ( $intf, $vip ) = @_;
  for my $dev ( keys %{$intf} ) {
    my $inet = $intf->{$dev}{inet} or next;
    my $i = 0;
    for my $addr ( @{$inet} ) {
      if ( $addr->{ip} eq $vip ) {
        return ( $vip, $addr->{bits}, $dev )
          if $i > 0;    # 1st entry is RIP rather than VIP
      }
      $i++;
    }
  }
  return;
}

sub find_dev {
  my ( $self, $vip ) = @_;

  my $output = $self->get_ipaddr() or return;
  my $intf = parse_ipaddr($output);

  return _find_dev( $intf, $vip );
}

sub find_dev_with_check {
  my ( $self, $vip ) = @_;

  my $output = $self->get_ipaddr() or return;
  my $intf = parse_ipaddr($output);

  return 1 if _check_vip( $intf, $vip );
  return _find_dev( $intf, $vip );
}

sub check_node_vip {
  my ( $self, $vip ) = @_;

  my $output = $self->get_ipaddr() or return;
  my $intf = parse_ipaddr($output);

  return _check_vip( $intf, $vip );
}

sub stop_vip {
  my ( $self, $vip ) = @_;
  my ( $ip, $bits, $dev ) = $self->check_node_vip($vip)
    or croak "vip $vip is not configured on the node";

  my $sudo = $self->{user} ne 'root' ? 'sudo' : '';
  $self->run_ssh_cmd("$sudo /sbin/ip addr del $ip/$bits dev $dev");
  assert_status();
  return ( $ip, $bits, $dev );
}

sub start_vip {
  my ( $self, $vip, $dev ) = @_;
  my @vip = $self->find_dev_with_check($vip);
  croak "vip $vip is already configured on the node"
    if @vip == 1;    # some suck trick
  $dev ||= $vip[2];  # third component
  croak "vip $vip does not match any device" unless defined $dev;

  my $sudo = $self->{user} ne 'root' ? 'sudo' : '';
  $self->run_ssh_cmd( "$sudo /sbin/ip addr add $vip dev $dev"
      . ( $dev =~ /^lo/ ? "" : "; $sudo /sbin/arping -U -I $dev -c 3 $vip" ) );
  assert_status();
}

1;


package MHA::Extra::Proxysql;

use strict;
use warnings;
use Carp;

use constant Proxysql_Read_Only => "PROXYSQL READONLY";
use constant Proxysql_Read_Write => "PROXYSQL READWRITE";
use constant Proxysql_Load_Variable_To_Runtime => "LOAD MYSQL VARIABLES TO RUNTIME";
use constant Proxysql_Load_Servers_To_Runtime => "LOAD MYSQL SERVERS TO RUNTIME";
use constant Proxysql_Save_Variable_To_Disk => "SAVE MYSQL SERVERS TO DISK";

use constant Proxysql_Delete_Repl_Group => 
  "DELETE FROM mysql_replication_hostgroups WHERE writer_hostgroup = ? AND reader_hostgroup = ?";
use constant Proxysql_Insert_Repl_Group => 
  "REPLACE INTO mysql_replication_hostgroups (writer_hostgroup, reader_hostgroup, comment) "
  . "VALUES (?, ?, ?)";
use constant Proxysql_Delete_Hostgroup => 
  "DELETE FROM mysql_servers WHERE hostgroup_id in (?, ?) AND hostname = ? AND port = ?";
use constant Proxysql_Insert_New_Server => 
  "REPLACE INTO mysql_servers " . 
  "(hostgroup_id, hostname, port, status, weight, max_connections, max_replication_lag) " .
  "VALUES (?, ?, ?, ?, ?, ?, ?)";

sub new {
  my ($class) = @_;
  bless {}, __PACKAGE__;
}

sub connect {
  my $self = shift;
  my $host = shift;
  my $port = shift;
  my $user = shift;
  my $password = shift;
  my $database = shift;
  my $raise_error = shift;
  $raise_error = 0 if ( !defined($raise_error) );
  my $defaults = { 
    PrintError => 0,
    RaiseError => ( $raise_error ? 1 : 0 ),
  };

  $database ||= "";
  my $dbh = eval {
    DBI->connect("DBI:mysql:database=$database;host=$host;port=$port",
      $user, $password, $defaults);
  };  
  if (!$dbh && $@) {
    carp "get proxysql connect for $host:$port error:$@";
    $self->{dbh}->undef;
  }
  $self->{dbh} = $dbh;
}

sub disconnect {
  my $self = shift;
  $self->{dbh}->disconnect();
}


sub proxysql_readonly {
  my $self = shift;
  my $failure = 0;
  my $ret = $self->{dbh}->do(Proxysql_Read_Only);
  unless ($ret eq "0E0") {
    $failure++;
  }
  else {
    $self->{dbh}->do(Proxysql_Load_Variable_To_Runtime);
  }
  if ($failure) {
    return 0;
  }
  return 1;
}

sub proxysql_readwrite {
  my $self = shift;
  my $failure = 0;
  my $ret = $self->{dbh}->do(Proxysql_Read_Write);
  unless ($ret eq "0E0") {
    $failure++;
  }
  else {
    $self->{dbh}->do(Proxysql_Load_Variable_To_Runtime);
  }
  if ($failure) {
    return 0;
  }
  return 1;
}

sub proxysql_delete_repl_group {
  my $self = shift;
  my $wgroup = shift;
  my $rgroup = shift;
  my $failure = 0;
  if ($wgroup && $rgroup) {
    eval {
      $self->{dbh}->do(Proxysql_Delete_Repl_Group, undef, $wgroup, $rgroup);
    };
    if ($@) {
      $failure++;
    }
  }
  else {
    $failure++;
  }
  if ($failure) {
    return 0;
  }
  return 1;
}

sub proxysql_insert_repl_group {
  my $self = shift;
  my $wgroup = shift;
  my $rgroup = shift;
  my $failure = 0;
  if ($wgroup && $rgroup) {
    eval {
      $self->{dbh}->do(Proxysql_Insert_Repl_Group, 
         undef, $wgroup, $rgroup, "MHA switch proxysql");
    };
    if ($@) {
      $failure++;
    }
  }
  else {
    $failure++
  }
  if ($failure) {
    return 0;
  }
  return 1;
}

sub proxysql_delete_group {
  my ($self, $wgroup, $rgroup, $host, $port) = @_;
  my $failure = 0;
  if ($wgroup && $rgroup && $host && $port) {
    eval {
      $self->{dbh}->do(Proxysql_Delete_Hostgroup, undef, $wgroup, $rgroup, $host, $port);
    };
    if ($@) {
      $failure++;
    }
  }
  else {
    $failure++;
  }
  if ($failure) {
    return 0;
  }
  return 1;
}

sub proxysql_insert_new_server {
  my ($self, $group, $host, $port, $lag) = @_;
  my $failure = 0;
  if ($group && $host && $port) {
    eval{
      $self->{dbh}->do(Proxysql_Insert_New_Server, undef, $group, $host, $port, 
            'ONLINE', 1000, 2000, $lag);
    };
    if ($@) {
      $failure++;
    }
  }
  else {
    $failure++;
  }
  if ($failure) {
    return 0;
  }
  return 1;
}

sub proxysql_load_server_to_runtime {
  my $self = shift;
  my $failure = 0;
  my $ret = $self->{dbh}->do(Proxysql_Load_Servers_To_Runtime);
  unless ($ret eq "0E0") {
    $failure++;
  }
  else {
    $self->{dbh}->do(Proxysql_Load_Variable_To_Runtime);
  }
  if ($failure) {
    return 0;
  }
  return 1;
}

sub proxysql_save_server_to_disk {
  my $self = shift;
  my $dbh = shift;
  my $failure = 0;
  my $ret = $self->{dbh}->do(Proxysql_Save_Variable_To_Disk);
  unless ($ret eq "0E0") {
    $failure++;
  }
  else {
    $self->{dbh}->do(Proxysql_Load_Variable_To_Runtime);
  }
  if ($failure) {
    return 0;
  }
  return 1;
}

1;

package MHA::Extra::DNS;
use strict;
use warnings;
use Carp;
use Net::DNS;

sub new {
  my ($class, %args) = @_;

  # must set servers and as anonymous array
  my @required_args = qw(consul_name consul_servers);
  foreach my $arg (@required_args) {
      die "I need a $arg argument" unless $args{$arg};
  }
  die "servers should be as anonymous array"
     unless ref($args{servers}) ne 'ARRAY';

  my $bin = $args{consul_bin} || '/usr/bin/consul';
  die "cann't found/execute consul command!"
     unless -x $bin;
  
  my $self = {
    consul_bin       => $bin,
    consul_name      => $args{consul_name},
    consul_token     => $args{consul_token},
    consul_servers   => $args{consul_servers},
    consul_dns_port  => $args{consul_dns_port}  || 53,
    consul_http_port => $args{consul_http_port} || 8500,
    consul_domain    => $args{consul_domain}    || 'consul',
  };

  bless $self, $class;
  return $self;
};

sub _exec_system {
  my $cmd     = shift;
  my $log_out = shift;

  if ($log_out) {
    return  _system_rc(system("$cmd >> $log_out 2>&1"));
  }
  else {
    return _system_rc(system($cmd));
  }
}

sub _system_rc {
  my $rc   = shift;
  my $high = $rc >> 8;
  my $low  = $rc & 255;
  return ($high, $low);
}

sub _exec_cmd_return {
  my $cmd  = shift;
  my $res;
  eval {
    $res = `$cmd`;
  };
  if ($@) {
    return "Err: $@";
  }
  chomp($res);
  return $res;
}

sub is_dns_ok {
  my $self = shift;
  my $ip   = shift;

  return 0 unless (defined $ip && length($ip));

  my $status = 1;
  my $list = $self->{consul_name}
           . ".service." 
           . $self->{consul_domain};

  foreach my $s (@{$self->{consul_servers}}) {
    my $res  = Net::DNS::Resolver->new(
      nameservers => [$s],
      port        => $self->{consul_dns_port},
      recurse     => 0,
      tcp_timeout => 2,
      udp_timeout => 2,
    );

    my @records;
    my $reply = $res->query($list, 'A');
    if ($reply) {
      foreach my $r ($reply->answer) {
        next unless $r->type eq 'A';
        push @records, $r->address if defined $r->address;
      }
    }

    if (@records == 0) {
      print "ERROR - can not find $list from dns server $s\n";
      $status = 0;
      next;
    }
    if (@records + 0 > 1) {
      print "ERROR - dns check for server $s resolver multiple ip: "
            . join(", ", @records);
      $status = 0;
      next;
    }
    if ($records[0] eq "$ip") {
      print "OK - dns check for server $s, item: $list, resolve: $ip\n";
    }
    else {
      print "ERROR - dns check for: server $s, item: $list, resolve: $ip!\n";
      $status = 0;
    }
  }
  return $status;
}

sub delete_dns {
  my $self   = shift;
  my $status = 1;

  my $name = $self->{consul_name};

  # set access token
  $ENV{CONSUL_HTTP_TOKEN} = $self->{consul_token} if defined $self->{consul_token};

  my $http_port = $self->{consul_http_port};
  foreach my $k (@{$self->{consul_servers}}) {
    $ENV{CONSUL_HTTP_ADDR} = "$k:$http_port";
    my ($high, $low) = _exec_system(
        "$self->{consul_bin} services deregister -id $name"
      );

    if ($high != 0 || $low != 0) {
      print "ERROR - deregister service $name error from $k:$http_port\n";
      $status = 0;
    }
    else {
      print "OK - deregister service $name ok from $k:$http_port\n";
    }
  }
  $ENV{CONSUL_HTTP_ADDR} = "localhost:$http_port";
  sleep 1; # wait a moment

  return $status;
}

sub create_dns {
  my $self   = shift;
  my $ip     = shift;
  my $port   = shift || undef;
  my $status = 1;

  return 0 unless defined $ip;

  my $name = $self->{consul_name};
  my $cmd  = do {
    if (defined $port) {
      "$self->{consul_bin} services register -name $name -address $ip -port $port -tag mysql -kind db";
    }
    else {
      "$self->{consul_bin} services register -name $name -address $ip -tag mysql -kind db";
    }
  };

  # set access token
  $ENV{CONSUL_HTTP_TOKEN} = $self->{consul_token} if defined $self->{consul_token};

  my $http_port = $self->{consul_http_port};
  foreach my $k (@{$self->{consul_servers}}) {
    $ENV{CONSUL_HTTP_ADDR} = "$k:$http_port";
    my ($high, $low) = _exec_system(
        "$cmd"
    );
    if ($high != 0 || $low != 0) {
      print "ERROR - register service $name - $ip:$port error from $k:$http_port\n";
      $status = 0;
    }
    else {
      print "OK - register service $name - $ip:$port ok from $k:$http_port\n";
    }
  }

  $ENV{CONSUL_HTTP_ADDR} = "localhost:$http_port";
  sleep 1; # wait a moment

  return $status;
}

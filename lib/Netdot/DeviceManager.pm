package Netdot::DeviceManager;

use lib "PREFIX/lib";
use lib "NVPREFIX/lib";
use NetViewer::RRD::SNMP::NV;

use base qw( Netdot );
use Netdot::DBI;
use Netdot::UI;
use Netdot::IPManager;
use Netdot::DNSManager;
use strict;

#Be sure to return 1
1;


######################################################################
# Constructor
######################################################################
sub new { 
    my ($proto, %argv) = @_;
    my $class = ref( $proto ) || $proto;
    my $self = {};
    bless $self, $class;
    $self->{'_snmpversion'}   = $argv{'logfacility'} || $self->{'DEFAULT_SNMPVERSION'},
    $self->{'_snmpcommunity'} = $argv{'logfacility'} || $self->{'DEFAULT_SNMPCOMMUNITY'},
    $self->{'_snmpretries'}   = $argv{'logfacility'} || $self->{'DEFAULT_SNMPRETRIES'},
    $self->{'_snmptimeout'}   = $argv{'logfacility'} || $self->{'DEFAULT_SNMPTIMEOUT'},

    $self = $self->SUPER::new( %argv );

    $self->{nv} = NetViewer::RRD::SNMP::NV->new(aliases     => "PREFIX/etc/categories",
						snmpversion => $self->{'_snmpversion'},
						community   => $self->{'_snmpcommunity'},
						retries     => $self->{'_snmpretries'},
						timeout     => $self->{'_snmptimeout'},
						);
    $self->{ui}  = Netdot::UI->new();
    $self->{ipm} = Netdot::IPManager->new();
    $self->{dns} = Netdot::DNSManager->new();
    $self->{badhubs} = {};
    foreach my $oid (split /\s+/, $self->{'BADHUBS'}){
	$self->{badhubs}->{$oid} = '';
    }
    
    wantarray ? ( $self, '' ) : $self; 
}

#####################################################################
# Store (appended) output for interactive use
#####################################################################
sub output {
    my $self = shift;
    if (@_){ 
	$self->{'_output'} .= shift;
	$self->{'_output'} .= "\n";
    }
    return $self->{'_output'};
}
#####################################################################
# Clear output buffer
#####################################################################
sub _clear_output {
    my $self = shift;
    $self->{'_output'} = undef;
}

#####################################################################
# Convert hex values returned from SNMP into a readable string
#####################################################################
sub _readablehex {
    my ($self, $v) = @_;
    my $h = sprintf('%s', unpack('H*', $v));
    return uc($h);
}

#####################################################################
# Find Device
# Performs some lookups in various places to determine
# if device exists in DB
#####################################################################
sub find_dev {
    my ($self, $host) = @_;
    my ($device, $comstr);
    $self->error(undef);
    $self->_clear_output();

    if ($device = $self->{dns}->getdevbyname($host)){
	my $msg = sprintf("Device %s exists in DB.  Will try to update", $host);
	$self->debug( loglevel => 'LOG_NOTICE',
		      message  => $msg );
	$self->output($msg);
	$comstr = $device->community
    }elsif($self->{dns}->getrrbyname($host)){
	my $msg = sprintf("Name %s exists but Device not in DB.  Will try to create", $host);
	$self->debug( loglevel => 'LOG_NOTICE',
		      message  => $msg );
	$self->output($msg);
    }elsif(my $ip = $self->{ipm}->searchblock($host)){
	if ( $ip->interface && ($device = $ip->interface->device) ){
	    my $msg = sprintf("Device with address %s exists in DB. Will try to update", $ip->address);
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => $msg );
	    $self->output($msg);
	    $comstr = $device->community;
	}else{
	    my $msg = sprintf("Address %s exists but Device not in DB.  Will try to create", $host);
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => $msg );
	    $self->output($msg);
	    $self->output();
	}
    }else{
	$self->output(sprintf("Device %s not in DB.  Will try to create", $host));
    }
    return ($comstr, $device);
}

#####################################################################
# Update device
# This method can be called from Netdot's web components or 
# from independent scripts.  Should be able to update existing 
# devices or create new ones
#
# Required Args:
#   host:  name or ip address of host to query
# Optional args:
#   device: Existing 'Device' object 
#   comstr: SNMP community string (default "public")
#####################################################################
sub update {
    my ($self, %argv) = @_;
    my ($host, $comstr, %dev, $device, $dvn, %ifs, %dbifdeps);
    $self->error(undef);
    $self->_clear_output();

    $self->debug(loglevel => 'LOG_DEBUG',
		 message => "Arguments are: %s" ,
		 args => [ join ', ', map {"$_ = $argv{$_}"} keys %argv ]);
    
    unless ( ($host   =    $argv{host})   &&
	     ($comstr =    $argv{comstr}) && 
	     (%dev    =  %{$argv{dev}}) ){
	$self->error( sprintf("Missing required arguments") );
	$self->debug(loglevel => 'LOG_ERR',
		     message => $self->error);
	return 0;
    }
    $device = $argv{device} if exists $argv{device};
    
    if ( $device ){
	################################################     
	# Keep a hash of stored Interfaces for this Device
	map { $ifs{ $_->id } = $_ } $device->interfaces();

	# 
	# Get all stored interface dependencies, associate with ip
	# 
	foreach my $ifid (keys %ifs){
	    my $if = $ifs{$ifid};
	    foreach my $dep ( $if->parents() ){		
		foreach my $ip ( $if->ips() ){
		    $dbifdeps{$if->id}{$ip->address} = $dep;
		    $self->debug( loglevel => 'LOG_DEBUG',
				  message  => "Interface %s,%s with ip %s had parent %s:%s",
				  args => [$if->number, $if->name, $ip->address, 
					   $dep->parent->device->name->name, 
					   $dep->parent->name] );
		}
	    }
	    foreach my $dep ( $if->children() ){
		foreach my $ip ( $if->ips() ){
		    $dbifdeps{$if->id}{$ip->address} = $dep;
		    $self->debug( loglevel => 'LOG_DEBUG',
				  message  => "Interface %s,%s with ip %s had child %s:%s",
				  args => [$if->number, $if->name, $ip->address, 
					   $dep->child->device->name->name, 
					   $dep->child->name] );
		}
	    }
	}
    }
    my %devtmp;
    $devtmp{sysdescription} = $dev{sysdescription};
    $devtmp{community} = $comstr;
    ##############################################
    # Make sure name is in DNS

    my $zone = $self->{'DEFAULT_DNSDOMAIN'};
    my $rr;
    if ( $rr = $self->{dns}->getrrbyname($host) ) {
	my $msg = sprintf("Name %s exists in DB. Pointing to it", $host);
	$self->debug( loglevel => 'LOG_NOTICE',
		      message  => $msg);
	$self->output($msg);
	$devtmp{name} = $rr;
    }elsif($device && $device->name && $device->name->name){
	my $msg = sprintf("Device %s exists in DB as %s. Keeping existing name", $host, $device->name->name);
	$self->debug( loglevel => 'LOG_NOTICE',
		      message  => $msg);
	$self->output($msg);
	$devtmp{name} = $device->name;
    }else{
	my $msg = sprintf ("Name %s not in DB. Adding DNS entry.", $host);
	$self->debug( loglevel => 'LOG_NOTICE',
		      message  => $msg );
	$self->output($msg);
	unless ($self->{dns}->getzonebyname($zone)){
	    my $msg = sprintf("Zone %s does not exist in DNS. Creating", $host);
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => $msg );
	    $self->output($msg);
	    $self->debug( loglevel => 'LOG_DEBUG',
			  message => "SOA defaults are: refresh: %s, retry: %s, expire: %s, minimum: %s", 
			  args => [ $self->{'DEFAULT_DNSREFRESH'}, 
				    $self->{'DEFAULT_DNSRETRY'}, 
				    $self->{'DEFAULT_DNSEXPIRE'}, 
				    $self->{'DEFAULT_DNSMINIMUM'} ] );	    	 
	    unless ($self->{dns}->insertzone(mname => $zone)){
		$self->debug( loglevel => 'LOG_ERR',
			      message  => "Could not insert Zone %s to DB: %s",
			      args => [$zone, $self->{dns}->error]);	    
	    }
	}
	if ($rr = $self->{dns}->insertrr(name => $host,
				type => "A",
				zone => $zone,
				)){
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => "Inserted name %s into DB",
			  args => [ $host . "\." . $zone ], 
			  );	    
	    $devtmp{name} = $rr;
	}else{
	    my $msg = sprintf("Could not insert DNS entry %s: %s", $host, $self->{dns}->error);
	    $self->debug( loglevel => 'LOG_ERR',
			  message  => $msg
			  );	    
	    $self->error($msg);
	    return 0;
	}
    }

    ###############################################
    # Try to assign Product based on SysObjectID

    if( my $prod = (Product->search( sysobjectid => $dev{sysobjectid} ))[0] ) {
	$self->debug( loglevel => 'LOG_INFO',
		      message  => "SysID matches %s", 
		      args     => [$prod->name]);
	$devtmp{productname} = $prod->id;
    }else{
	$self->debug( loglevel => 'LOG_INFO',
		      message  => "New product with SysID %s.  Adding to DB",
		      args     => [$dev{sysobjectid}]);
	
	###############################################
	# Create a new product entry
	
	my $oid = $dev{enterprise};
	my $ent;
	if($ent = (Entity->search( oid => $oid ))[0] ) {
	    $self->debug( loglevel => 'LOG_INFO',
			  message  => "Manufacturer OID matches %s", 
			  args     => [$ent->name]);
	}else{
	    $self->debug( loglevel => 'LOG_INFO',
			  message  => "Entity with Enterprise OID %s not found. Creating", 
			  args => [$oid]);
	    my $t;
	    unless ( $t = (EntityType->search(name => "Manufacturer"))[0] ){
		$t = 0; 
	    }
	    my %enttmp = ( name => $oid,
			   oid  => $oid,
			   type => $t,
			   );
	    if ( ($ent = $self->{ui}->insert(table => 'Entity', 
					     state => { name => $oid,
							oid  => $oid,
							type => $t })
		  ) ){
		my $msg = sprintf("Created Entity with Enterprise OID: %s.  Please set name, etc.", $oid);
		$self->debug( loglevel => 'LOG_NOTICE',
			      message  => $msg );		
	    }else{
		$self->debug( loglevel => 'LOG_ERR',
			      message  => "Could not create new Entity with oid: %s: %s",
			      args     => [$oid, $self->{ui}->error],
			      );
		$ent = 0;
	    }
	}
	my %prodtmp = ( name         => $dev{sysobjectid},
			description  => $dev{sysdescription},
			sysobjectid  => $dev{sysobjectid},
			type         => 0,
			manufacturer => $ent,
			);
	my $newprodid;
	if ( ($newprodid = $self->{ui}->insert(table => 'Product', state => \%prodtmp)) ){
	    my $msg = sprintf("Created product with SysID: %s.  Please set name, type, etc.", $dev{sysobjectid});
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => $msg );		
	    $devtmp{productname} = $newprodid;
	}else{
	    $self->debug( loglevel => 'LOG_ERR',
			  message  => "Could not create new Product with SysID: %s: %s",
			  args     => [$dev{sysobjectid}, $self->{ui}->error],
			  );		
	    $devtmp{productname} = 0;
	}
    }
    ###############################################
    # Update/add PhsyAddr for Device
    
    if( defined $dev{physaddr} ) {
	# Look it up
	if (my $phy = (PhysAddr->search(address => $dev{physaddr}))[0] ){
	    if ( ! $device ){
		if ( my $otherdev = (Device->search(physaddr => $phy->id))[0] ){
		    #
		    # Another device exists that has that address
		    # 
		    my $name = (defined($otherdev->name->name))? $otherdev->name->name : $otherdev->id;
		    $self->error( sprintf("PhysAddr %s belongs to existing device %s. Aborting", 
					  $dev{physaddr}, $name ) ); 
		    $self->debug( loglevel => 'LOG_ERR',
				  message  => $self->error,
				  );
		    return 0;
		}
	    }else{
		#
		# The address exists (maybe discovered in fw tables/arp cache)
		# Just point to it from this Device
		#
		$devtmp{physaddr} = $phy->id;
		$self->{ui}->update( object => $phy, 
				     state  => {last_seen => $self->{ui}->timestamp },
				     );
	    }
	    $self->debug( loglevel => 'LOG_INFO',
			  message  => "Pointing to existing %s as base bridge address",
			  args => [$dev{physaddr}],
			  );		
	    #
	    # address is new.  Add it
	    #
	}else{
	    my %phaddrtmp = ( address => $dev{physaddr},
			      last_seen => $self->{ui}->timestamp,
			      );
	    my $newphaddr;
	    if ( ! ($newphaddr = $self->{ui}->insert(table => 'PhysAddr', state => \%phaddrtmp)) ){
		$self->debug( loglevel => 'LOG_ERR',
			      message  => "Could not create new PhysAddr: %s: %s",
			      args => [$phaddrtmp{address}, $self->{ui}->error],
			      );
		$devtmp{physaddr} = 0;
	    }else{
		$self->debug( loglevel => 'LOG_NOTICE',
			      message  => "Added new PhysAddr: %s",
			      args => [$phaddrtmp{address}],
			      );		
		$devtmp{physaddr} = $newphaddr;
	    }
	}
    }else{
	$self->debug( loglevel => 'LOG_INFO',
		      message  => "Device did not return dot1dBaseBridgeAddress",
		      );		
    }
    ###############################################
    # Serial Number
    
    if( defined $dev{serialnumber} ) {

	if ( ! $device ){
	    if ( my $otherdev = (Device->search(serialnumber => $dev{serialnumber}))[0] ){
		
		$self->error( sprintf("S/N %s belongs to existing device %s. Aborting.", 
				      $dev{serialnumber}, $host) ); 
		$self->debug( loglevel => 'LOG_ERR',
			      message  => $self->error,
			      );
		return 0;
	    }
	}
	$devtmp{serialnumber} = $dev{serialnumber};
    }else{
	$self->debug( loglevel => 'LOG_INFO',
		      message  => "Device did not return serial number",
		      );		
    }
    ###############################################
    # Update/Add Device
    
    if ( $device ){
	$devtmp{lastupdated} = $self->{ui}->date;
	unless( $self->{ui}->update( object => $device, state => \%devtmp ) ) {
	    $self->error( sprintf("Error updating device %s: %s", $host, $self->{ui}->error) ); 
	    $self->debug( loglevel => 'LOG_ERR',
			  message  => $self->error,
			  );
	    return 0;
	}
    }else{
	# Some Defaults
	# 
	$devtmp{monitored}        = 1;
	$devtmp{snmp_managed}     = 1;
	$devtmp{canautoupdate}    = 1;
	$devtmp{customer_managed} = 0;
	$devtmp{natted}           = 0;
	$devtmp{dateinstalled}    = $self->{ui}->date;
	my $newdevid;
	unless( $newdevid = $self->{ui}->insert( table => 'Device', state => \%devtmp ) ) {
	    $self->error( sprintf("Error creating device %s: %s", $host, $self->{ui}->error) ); 
	    $self->debug( loglevel => 'LOG_ERR',
			  message  => $self->error,
			  );
	    return 0;
	}
	$device = Device->retrieve($newdevid);
    }

    ##############################################
    # for each interface just discovered...

    my (%dbips, %newips, %dbvlans, %ifvlans);

    foreach my $newif ( keys %{ $dev{interface} } ) {

	############################################
	# set up IF state data
	my( %iftmp, $if );
	$iftmp{device} = $device->id;

	my %iffields = ( number      => "",
			  name        => "",
			  type        => "",
			  description => "",
			  speed       => "",
			  status      => "" );

	foreach my $field ( keys %{ $dev{interface}{$newif} } ){
	    if (exists $iffields{$field}){
		$iftmp{$field} = $dev{interface}{$newif}{$field};
	    }
	}

	$iftmp{monitored} = 1 if exists ($dev{interface}{$newif}{ips});

	###############################################
	# Update/add PhsyAddr for Interface
	if (defined (my $addr = $dev{interface}{$newif}{physaddr})){
	    # Look it up
	    if (my $phy = (PhysAddr->search(address => $addr))[0] ){
		#
		# The address exists 
		# Just point to it from this Interface
		#
		$iftmp{physaddr} = $phy->id;
		$self->{ui}->update( object => $phy, 
			     state => {last_seen => $self->{ui}->timestamp} );
		$self->debug( loglevel => 'LOG_INFO',
			      message  => "Interface %s,%s has existing PhysAddr %s",
			      args => [$iftmp{number}, $iftmp{name}, $addr],
			      );		
		#
		# address is new.  Add it
		#
	    }else{
		my %phaddrtmp = ( address => $addr,
				  last_seen => $self->{ui}->timestamp,
				  );
		my $newphaddr;
		if ( ! ($newphaddr = $self->{ui}->insert(table => 'PhysAddr', state => \%phaddrtmp)) ){
		    $self->debug( loglevel => 'LOG_ERR',
				  message  => "Could not create new PhysAddr %s for Interface %s,%s: %s",
				  args     => [$phaddrtmp{address}, 
					       $iftmp{number}, 
					       $iftmp{name}, 
					       $self->{ui}->error],
				  );
		    $iftmp{physaddr} = 0;
		}else{
		    $self->debug( loglevel => 'LOG_INFO',
				  message  => "Added new PhysAddr %s for Interface %s,%s",
				  args => [$phaddrtmp{address}, $iftmp{number}, $iftmp{name}],
				  );		
		    $iftmp{physaddr} = $newphaddr;
		}
	    }
	}
	############################################
	# Add/Update interface
	if ( $if = (Interface->search(device => $device->id, 
				      number => $iftmp{number}))[0] ) {
	    delete( $ifs{ $if->id } );
	    
	    unless( $self->{ui}->update( object => $if, state => \%iftmp ) ) {
		my $msg = sprintf("Could not update Interface %s,%s: .", 
				  $iftmp{number}, $iftmp{name}, $self->{ui}->error);
		$self->debug( loglevel => 'LOG_ERR',
			      message  => $msg,
			      );
		$self->output($msg);
		next;
	    }
	} else {
	    $iftmp{monitored} = 0;
	    $iftmp{speed}   ||= 0; #can't be null
	    
	    my $msg = sprintf("Interface %s,%s doesn't exist. Inserting", $iftmp{number}, $iftmp{name} );
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => $msg,
			  );
	    $self->output($msg);
	    if ( ! (my $ifid = $self->{ui}->insert( table => 'Interface', 
					    state => \%iftmp )) ) {
		$msg = sprintf("Error inserting Interface %s,%s: %s", $iftmp{number}, $iftmp{name}, $self->{ui}->error);
		$self->debug( loglevel => 'LOG_ERR',
			      message  => $msg,
			      );
		$self->output($msg);
		next;
	    }else{
		unless( $if = Interface->retrieve($ifid) ) {
		    $msg = sprintf("Couldn't retrieve Interface id %s", $ifid);
		    $self->debug( loglevel => 'LOG_ERR',
				  message  => $msg );
		    $self->output($msg);
		    next;
		}
	    }
	    
	}
	################################################################
	# Keep a hash of VLAN membership
	# We'll Add/Update at the end
	
	if( exists( $dev{interface}{$newif}{vlans} ) ) {
	    foreach my $vid ( keys %{ $dev{interface}{$newif}{vlans} } ){
		my $vname = $dev{interface}{$newif}{vlans}{$vid};
		push @{$ifvlans{$vid}{$vname}}, $if->id;
	    }
	}
	# 
	# Get all stored VLAN memberships (these are join tables);
	#
	map { $dbvlans{$_->interface->id} = $_->id } $if->vlans();

	################################################################
	# Add/Update IPs
	
	if( exists( $dev{interface}{$newif}{ips} ) && ! $device->natted ) {	    
	    # Get all stored IPs belonging to this Interface
	    #
	    map { $dbips{$_->address} = $_->id } $if->ips();

	    foreach my $newip( keys %{ $dev{interface}{$newif}{ips}}){
		my( $ipobj, $maskobj, $subnet, $ipdbobj );
		my $version = ($newip =~ /:/) ? 6 : 4;
		my $prefix = ($version == 6) ? 128 : 32;
		# 
		# Keep all new ips in a hash
		$newips{$newip} = $if;
		
		if ( exists ($dbips{$newip}) ){
		    #
		    # update
		    my $msg = sprintf("%s's IP %s/%s exists. Updating", $if->name, $newip, $prefix);
		    $self->debug( loglevel => 'LOG_NOTICE',
				  message  => $msg );
		    $self->output($msg);
		    my $ifid = $dbips{$newip};
		    delete( $dbips{$newip} );
		    
		    unless( $self->{ipm}->updateblock(id        => $ifid, 
						      address   => $newip, 
						      prefix    => $prefix,
						      status    => "Assigned",
						      interface => $if )){
			my $msg = sprintf("Could not update IP %s/%s: %s", $newip, $prefix, $self->{ipm}->error);
			$self->debug( loglevel => 'LOG_ERR',
				      message  => $msg );
			$self->output($msg);
			next;
		    }

		}elsif ( my $dbip = $self->{ipm}->searchblock($newip) ){
		    # IP exists but not linked to this interface
		    # update
		    my $msg = sprintf("IP %s/%s exists but not linked to %s. Updating", 
				      $newip, $prefix, $if->name);
		    $self->debug( loglevel => 'LOG_NOTICE',
				  message  => $msg );
		    $self->output($msg);
		    unless( $self->{ipm}->updateblock(id        => $dbip->id, 
						      address   => $newip, 
						      prefix    => $prefix,
						      status    => "Assigned",
						      interface => $if )){
			my $msg = sprintf("Could not update IP %s/%s: %s", $newip, $prefix, $self->{ipm}->error);
			$self->debug( loglevel => 'LOG_ERR',
				      message  => $msg );
			$self->output($msg);
			next;
		    }
		}else {
		    my $msg = sprintf("IP %s doesn't exist.  Inserting", $newip);
		    $self->debug( loglevel => 'LOG_NOTICE',
				  message  => $msg );
		    $self->output($msg);
		    #
		    # Create a new Ip
		    unless( $self->{ipm}->insertblock(address   => $newip, 
						      prefix    => $prefix, 
						      status    => "Assigned",
						      interface => $if)){
			my $msg = sprintf("Could not insert IP %s: %s", $newip, $self->{ipm}->error);
			$self->debug( loglevel => 'LOG_ERR',
				      message  => $msg );
			$self->output($msg);
			next;
		    }else{
			my $msg = sprintf("Inserted IP %s", $newip);
			$self->debug( loglevel => 'LOG_NOTICE',
				      message  => $msg );
			$self->output($msg);
		    }
		}
		########################################################
		# Create subnet if device is a router (ipForwarding true)
		# and addsubnets flag is on

		if ( $dev{router} && $argv{addsubnets}){
		    my $newmask = $dev{interface}{$newif}{ips}{$newip};
		    my $subnetaddr = $self->{ipm}->getsubnetaddr($newip, $newmask);
		    if ( ! ($self->{ipm}->searchblock($subnetaddr, $newmask)) ){
			my $msg = sprintf("Subnet %s/%s doesn't exist.  Inserting", $subnetaddr, $newmask);
			$self->debug( loglevel => 'LOG_NOTICE',
				      message  => $msg );
			$self->output($msg);
			unless( $self->{ipm}->insertblock(address => $subnetaddr, 
							  prefix  => $newmask, 
							  status  => "Assigned") ){
			    my $err = $self->{ipm}->error();
			    my $msg = sprintf("Could not insert Subnet %s/%s: %s", 
					      $subnetaddr, $newmask, $err);
			    $self->debug(loglevel => 'LOG_ERR',
					 message  => $msg );
			    $self->output($msg);
			}else{
			    my $msg = sprintf("Created Subnet %s/%s", $subnetaddr, $newmask);
			    $self->debug(loglevel => 'LOG_NOTICE',
					 message  => $msg );
			    $self->output($msg);
			}
		    }else{
			my $msg = sprintf("Subnet %s/%s already exists", $subnetaddr, $newmask);
			$self->debug( loglevel => 'LOG_NOTICE',
				      message  => $msg );
			$self->output($msg);			    
		    }
		}
	    } # foreach newip
	} #if ips found 
    } #foreach $newif
    
    ##############################################
    # remove each interface that no longer exists
    #
    ## Do not remove manually-added ports for these hubs
    unless ( exists($self->{badhubs}->{$dev{sysobjectid}} )){
	
	foreach my $nonif ( keys %ifs ) {
	    my $ifobj = $ifs{$nonif};

	    ############################################################################
	    # Before removing, try to maintain dependencies finding another
	    # interface (any) that has one of this interface's ips
	    if (exists $dbifdeps{$nonif}){
		my $msg = sprintf("Interface %s,%s had dependency. Will try to maintain", 
				  $ifobj->number, $ifobj->name);
		$self->debug( loglevel => 'LOG_NOTICE',
			      message  => $msg,
			      );
		$self->output($msg);
		my $found = 0;
		foreach my $oldipaddr (keys %{$dbifdeps{$nonif}} ){
		    foreach my $newaddr (keys %newips ){
			if (exists ($newips{$oldipaddr}) ){
			    my $newif = $newips{$oldipaddr};
			    my $msg = sprintf("IP address %s is now on %s,%s.", 
					      $oldipaddr, $newif->number, $newif->name);
			    $self->debug( loglevel => 'LOG_DEBUG',
					  message  => $msg,
					  );
			    $self->output($msg);
			    my $ifdep = $dbifdeps{$nonif}{$oldipaddr};
			    my ($role, $rel);
			    if ($ifdep->parent->id eq $nonif) {
				$role = "parent"; 
				$rel = "child" ; 
			    }else{
				$role = "child"; 
				$rel = "parent"; 
			    }
			    unless ( $self->{ui}->update(object => $ifdep, state => {$role => $newif} )){
				my $msg = sprintf("Could not update Dependency for %s: %s", 
						  $nonif, $self->{ui}->error);
				$self->debug( loglevel => 'LOG_ERR',
					      message  => $msg,
					      );
				$self->output($msg);
			    }else{
				my $msg = sprintf("%s,%s is now %s of %s", 
						  $newif->number, $newif->name, $role, 
						  $ifdep->$rel->number, $ifdep->$rel->name);
				$self->debug( loglevel => 'LOG_ERR',
					      message  => $msg,
					      );
				$self->output($msg);
				
			    }
			    $found = 1;
			    last;
			}
		    }
		    if (! $found ){
			my $msg = sprintf("Found no interfaces with one of %s's addresses", $nonif);
			$self->debug( loglevel => 'LOG_NOTICE',
				      message  => $msg,
				      );
			$self->output($msg);
		    }
		}
	    }
	    my $msg = sprintf("Interface %s,%s no longer exists.  Removing.", $ifobj->number, $ifobj->name);
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => $msg,
			  );
	    $self->output($msg);
	    unless( $self->{ui}->remove( table => "Interface", id => $nonif ) ) {
		my $msg = sprintf("Could not remove Interface %s,%s: %s", 
				  $ifobj->number, $ifobj->name, $self->{ui}->error);
		$self->debug( loglevel => 'LOG_ERR',
			      message  => $msg,
			      );
		$self->output($msg);
		next;
	    }
	}
    }

    
    ##############################################
    # Add/Update VLANs
    # 
    
    foreach my $vid (keys %ifvlans){
	foreach my $vname (keys %{$ifvlans{$vid}}){
	    my $vo;
	    # look it up
	    unless ($vo = (Vlan->search(vid =>$vid))[0]){
		#create
		my %votmp = ( vid         => $vid,
			      description => $vname );
		if ( ! (my $vobjid = $self->{ui}->insert (table => "Vlan", state => \%votmp)) ) {
		    my $msg = sprintf("Could not insert Vlan %s: %s", 
				      $vo->description, $self->{ui}->error);
		    $self->debug( loglevel => 'LOG_ERR',
				  message  => $msg,
				  );
		    $self->output($msg);
		    next;
		}else {
		    $vo = Vlan->retrieve($vobjid);
		    my $msg = sprintf("Inserted VLAN %s", $vo->description);
		    $self->debug( loglevel => 'LOG_NOTICE',
				  message  => $msg,
				  );
		    $self->output($msg);
		}
	    }
	    # verify joins
	    foreach my $ifid ( @{ $ifvlans{$vid}{$vname} } ){
		my $if = Interface->retrieve($ifid);
		if( ! exists $dbvlans{$ifid} ){
		    my $msg = sprintf("Interface %s,%s should be part of vlan %s. Creating join.", 
				      $if->number, $if->name, $vo->vid);
		    $self->debug( loglevel => 'LOG_DEBUG',
				  message  => $msg,
				  );
		    my %jtmp = (interface => $if, vlan => $vo);
		    unless ( my $j = $self->{ui}->insert(table => "InterfaceVlan", state => \%jtmp) ){
			my $msg = sprintf("Could not insert InterfaceVlan join %s:%s: %s", 
					  $if->name, $vo->vid, $self->{ui}->error);
			$self->debug( loglevel => 'LOG_ERR',
				      message  => $msg,
				      );
			$self->output($msg);
		    }else{
			my $msg = sprintf("Assigned Interface %s,%s to VLAN %s", 
					  $if->number, $if->name, $vo->description);
			$self->debug( loglevel => 'LOG_NOTICE',
				      message  => $msg,
				      );
			$self->output($msg);
		    }
		}else {
		    my $msg = sprintf("Interface %s,%s already part of vlan %s", 
				      $if->number, $if->name, $vo->vid);
		    $self->debug( loglevel => 'LOG_DEBUG',
				  message  => $msg,
				  );
		    delete $dbvlans{$ifid};
		}
	    }
	}
    }
    
    ##############################################
    # remove each ip address that no longer exists
    
    unless ( $device->natted ){
	foreach my $nonip ( keys %dbips ) {
	    my $msg = sprintf("IP %s no longer exists.  Removing.", 
			      $nonip);
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => $msg,
			  );
	    $self->output($msg);		
	    unless( $self->{ipm}->removeblock( address => $nonip ) ) {
		my $msg = sprintf("Could not remove IP %s: %s", 
				  $nonip, $self->{ipm}->error);
		$self->debug( loglevel => 'LOG_ERR',
			      message  => $msg,
			      );
		$self->output($msg);
		next;
	    }
	}
    }

    ##############################################
    # remove each vlan membership that no longer exists
    
    foreach my $nonvlan ( keys %dbvlans ) {
	my $j = InterfaceVlan->retrieve($dbvlans{$nonvlan});
	my $msg = sprintf("Vlan membership %s:%s no longer exists.  Removing.", 
			  $j->interface->name, $j->vlan->vid);
	$self->debug( loglevel => 'LOG_NOTICE',
		      message  => $msg,
		      );
	$self->output($msg);		
	unless( $self->{ui}->remove( table => 'InterfaceVlan', id => $nonvlan ) ) {
	    my $msg = sprintf("Could not remove InterfaceVlan %s: %s", 
			      $j->id, $self->{ui}->error);
	    $self->debug( loglevel => 'LOG_ERR',
			  message  => $msg,
			  );
	    $self->output($msg);
	    next;
	}
	
    }
    ##################################################################
    # If device has only one IP, assign subnet's entity to it
    # 
   if ( (scalar(keys %newips)) == 1 ){
    
	unless ($device->entity != 0){
	    my $ipaddr = (keys(%newips))[0];
	    if ( my $ipobj = $self->{ipm}->searchblock($ipaddr) ){
		if ((my $subnet = $ipobj->parent) != 0 ){
		    if ( $subnet->entity != 0 ){
			$devtmp{entity} = $subnet->entity->id;
			my $msg = sprintf("Assigning subnet's entity \'%s\' to %s", 
					  $subnet->entity->name, $host);
			$self->debug( loglevel => 'LOG_NOTICE',
				      message  => $msg );
			$self->output($msg);
		    }
		}
	    }
	}
   }
    ################################################################
    # Update device if any changes since creation
    
    unless ( $self->{ui}->update( object => $device, state => \%devtmp ) ){
	my $msg = sprintf("Could not update Device %s: %s", 
			  $host, $self->{ui}->error);
	$self->debug(loglevel => 'LOG_ERR',
		     message  => $msg,
		     );
	$self->output($msg);
    }

    my $msg = sprintf("Discovery of %s completed\n\n", $host);
    $self->debug( loglevel => 'LOG_NOTICE',
		  message  => $msg );
    $self->output($msg);
    return $device;
}

#####################################################################
# get_dev_info
# 
# Use the SNMP libraries to get a hash with the device's information
# This should hide all possible underlying SNMP code logic from our
# device insertion/update code
#
# Required Args:
#   host:  name or ip address of host to query
#   comstr: SNMP community string
# Optional args:
#  
#####################################################################
sub get_dev_info {
    my ($self, $host, $comstr) = @_;
    $self->error(undef);
    $self->_clear_output();

    $self->{nv}->build_config( "device", $host, $comstr );
    my (%nv, %dev);
    unless( (%nv  = $self->{nv}->get_device( "device", $host )) &&
	    exists $nv{sysUpTime} ) {
	$self->error(sprintf ("Could not reach device %s", $host) );
	$self->debug(loglevel => 'LOG_ERR',
		     message => $self->error, 
		     );
	return 0;
    }
    if ( $nv{sysUpTime} < 0 ) {
	$self->error( sprintf("Device %s did not respond", $host) );
	$self->debug( loglevel => 'LOG_ERR',
		      message => $self->error);
	return 0;
    }
    my $msg = sprintf("Contacted Device %s", $host);
    $self->debug( loglevel => 'LOG_NOTICE',
		  message => $msg );
    $self->output($msg);

    ################################################################
    # Device's global vars

    if (defined $nv{sysObjectID}){
	$dev{sysobjectid} = $nv{sysObjectID};
	$dev{sysobjectid} =~ s/^\.(.*)/$1/;  #Remove unwanted first dot
	$dev{enterprise} = $dev{sysobjectid};
	$dev{enterprise} =~ s/(1\.3\.6\.1\.4\.1\.\d+).*/$1/;

    }
    if ( exists ($nv{sysName}) && length ($nv{sysName}) > 0 ){
	$dev{sysname} = $nv{sysName};
    }
    if ( exists ($nv{sysDescr}) && length ($nv{sysDescr}) > 0 ){
	$dev{sysdescription} = $nv{sysDescr};
    }
    if ( exists ($nv{sysContact}) && length ($nv{sysContact}) > 0 ){
	$dev{syscontact} = $nv{sysContact};
    }
    if ( exists ($nv{sysLocation}) && length ($nv{sysLocation}) > 0 ){
	$dev{syslocation} = $nv{sysLocation};
    }
    if ( exists ($nv{ipForwarding}) && $nv{ipForwarding} == 1 ){
	$dev{router} = 1;
    }
    if( exists ($nv{dot1dBaseBridgeAddress}) && length($nv{dot1dBaseBridgeAddress}) > 0  ) {
	# Canonicalize address
	$dev{physaddr} = $self->_readablehex($nv{dot1dBaseBridgeAddress});
    }
    if( exists ($nv{entPhysicalSerialNum}) && length($nv{entPhysicalSerialNum}) > 0  ) {
	$dev{serialnumber} = $nv{entPhysicalSerialNum};
    }

    ################################################################
    # Interface stuff

    ################################################################
    # MAU-MIB's ifMauType to half/full translations
    my %Mau2Duplex = ( '13.6.1.2.1.26.4.10' => "half",
		       '1.3.6.1.2.1.26.4.11' => "full",
		       '1.3.6.1.2.1.26.4.12' => "half",
		       '1.3.6.1.2.1.26.4.13' => "full",
		       '1.3.6.1.2.1.26.4.15' => "half",
		       '1.3.6.1.2.1.26.4.16' => "full",
		       '1.3.6.1.2.1.26.4.17' => "half",
		       '1.3.6.1.2.1.26.4.18' => "full",
		       '1.3.6.1.2.1.26.4.19' => "half",
		       '1.3.6.1.2.1.26.4.20' => "full",
		       '1.3.6.1.2.1.26.4.21' => "half",
		       '1.3.6.1.2.1.26.4.22' => "full",
		       '1.3.6.1.2.1.26.4.23' => "half",
		       '1.3.6.1.2.1.26.4.24' => "full",
		       '1.3.6.1.2.1.26.4.25' => "half",
		       '1.3.6.1.2.1.26.4.26' => "full",
		       '1.3.6.1.2.1.26.4.27' => "half",
		       '1.3.6.1.2.1.26.4.28' => "full",
		       '1.3.6.1.2.1.26.4.29' => "half",
		       '1.3.6.1.2.1.26.4.30' => "full",
		       );
    
    ################################################################
    # Catalyst's portDuplex to half/full translations
    my %CatDuplex = ( 1 => "half",
		      2 => "full",
		      3 => "auto",  #(*)
		      4 => "auto",
		      );
    # (*) MIB says "disagree", but we can assume it was auto and the other 
    # end wasn't
    
    my @ifrsv = split /\s+/, $self->{'IFRESERVED'};
    
    $self->debug( loglevel => 'LOG_DEBUG',
		  message => "Ignoring Interfaces: %s", 
		  args => [ join ', ', @ifrsv ] );	    	 
    
    ##############################################
    # Netdot to Netviewer field name translations
    # (values that are stored directly)

    my %iffields = ( number      => "instance",
		     name        => "name",
		     type        => "ifType",
		     description => "descr",
		     speed       => "ifSpeed",
		     status      => "ifAdminStatus" );

    ##############################################
    # for each interface discovered...
    
    foreach my $newif ( keys %{ $nv{interface} } ) {
	############################################
	# check whether should skip IF
	my $skip = 0;
	foreach my $n ( @ifrsv ) {
	    if( $nv{interface}{$newif}{name} =~ /$n/ ) { $skip = 1; last }
	}
	next if( $skip );

	foreach my $dbname ( keys %iffields ) {
	    # Ignore these descriptions
	    if( $dbname eq "description" ) {
		if( $nv{interface}{$newif}{$iffields{$dbname}} ne "-" &&
		    $nv{interface}{$newif}{$iffields{$dbname}} ne "not assigned" ) {
		    $dev{interface}{$newif}{$dbname} = $nv{interface}{$newif}{$iffields{$dbname}};
		}
	    }else {
		$dev{interface}{$newif}{$dbname} = $nv{interface}{$newif}{$iffields{$dbname}};
	    }
	}
	if (exists ($nv{interface}{$newif}{ifPhysAddress}) && 
	    length($nv{interface}{$newif}{ifPhysAddress}) > 0 ){
	    $dev{interface}{$newif}{physaddr} = $self->_readablehex($nv{interface}{$newif}{ifPhysAddress});
	}
	################################################################
	# Set Duplex mode
	my $dupval;
	################################################################
	# Standard MIB
	if (defined($nv{interface}{$newif}{ifMauType})){
	    $dupval = $nv{interface}{$newif}{ifMauType};
	    $dupval =~ s/^\.(.*)/$1/;
	    $dev{interface}{$newif}{duplex} = (exists ($Mau2Duplex{$dupval})) ? $Mau2Duplex{$dupval} : "unknown";
	    ################################################################
	    # Other Standard (used by some HP)	    
	}elsif(defined($nv{interface}{$newif}{ifSpecific})){
	    $dupval = $nv{interface}{$newif}{ifSpecific};
	    $dupval =~ s/^\.(.*)/$1/;
	    $nv{interface}{$newif}{duplex} = (exists ($Mau2Duplex{$dupval})) ? $Mau2Duplex{$dupval} : "unknown";
	    ################################################################
	    # Catalyst
	}elsif(defined($nv{interface}{$newif}{portDuplex})){
	    $dupval = $nv{interface}{$newif}{portDuplex};
	    $nv{interface}{$newif}{duplex} = (exists ($CatDuplex{$dupval})) ? $CatDuplex{$dupval} : "unknown";
	}

	####################################################################
	# IP addresses and masks 
	# (mask is the value for each ip address key)
	foreach my $ip( keys %{ $nv{interface}{$newif}{ipAdEntIfIndex}}){
	    $dev{interface}{$newif}{ips}{$ip} = $nv{interface}{$newif}{ipAdEntIfIndex}{$ip};
	}

	################################################################
	# Vlan info
	my ($vid, $vname);
	################################################################
	# Standard MIB
	if( defined( $nv{interface}{$newif}{dot1qPvid} ) ) {
	    $vid = $nv{interface}{$newif}{dot1qPvid};
	    $vname = ( defined($nv{interface}{$newif}{dot1qVlanStaticName}) ) ? 
		$nv{interface}{$newif}{dot1qVlanStaticName} : $vid;
	    $dev{interface}{$newif}{vlans}{$vid} = $vname;
	    ################################################################
	    # HP
	}elsif( defined( $nv{interface}{$newif}{hpVlanMemberIndex} ) ){
	    $vid = $nv{interface}{$newif}{hpVlanMemberIndex};
	    $vname = ( defined($nv{interface}{$newif}{hpVlanIdentName}) ) ?
		$nv{interface}{$newif}{hpVlanIdentName} : $vid;
	    $dev{interface}{$newif}{vlans}{$vid} = $vname;
	    ################################################################
	    # Cisco
	}elsif( defined( $nv{interface}{$newif}{vmVlan} )){
	    $vid = $nv{interface}{$newif}{vmVlan};
	    $vname = ( defined($nv{cviRoutedVlan}{$vid.0}{name}) ) ? 
		$nv{cviRoutedVlan}{$vid.0}{name} : $vid;
	    $dev{interface}{$newif}{vlans}{$vid} = $vname;
	}

    }
    ##############################################
    # for each hubport discovered...
    if ( ! exists($self->{badhubs}->{$nv{sysObjectID}} )){
	foreach my $newport ( keys %{ $nv{hubPorts} } ) {
	    
	    $dev{interface}{$newport}{name} = $newport;
	    $dev{interface}{$newport}{number} = $newport;
	    $dev{interface}{$newport}{speed} = 10000000; #most likely
	    
	} #foreach newport
    } #unless badhubs
    
    return \%dev;
}

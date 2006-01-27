#!/usr/bin/perl

# Generate a text file with a simple list of Devices
# with their types, ip addresses and parents (uplink devices),
# grouped by the building their located in and their subnet
#
# 
use NetdotExport;
use lib "<<Make:LIB>>";
use Netdot::DBI;
use strict;

my $DIR = "<<Make:PREFIX>>/export";
my $FILE = "$DIR/master.cnf";

my $DEBUG = 0;

my %hosts;
my %entities;
my %ip2name;
my %name2ip;

my %types = (
	'Access Point'     => 'access-point', 
	'DSL Modem'	   => 'dsl-modem',
	'Firewall'         => 'host',
	'Hub'		   => 'hub',
	'IP Phone'	   => 'host',
	'Packet Shaper'	   => 'host',
	'Router'           => 'router',
	'Server'	   => 'host',
	'Switch'	   => 'switch',
	'Wireless Bridge'  => 'access-point',
	'Wireless Gateway' => 'access-point',
	 
);

open (FILE, ">$FILE")
    or die "Couldn't open $FILE for writing: $!\n";

select (FILE);

print "#            ****        THIS FILE WAS GENERATED FROM A DATABASE         ****\n";
print "#            ****           ANY CHANGES YOU MAKE WILL BE LOST            ****\n";
print "#  Generated by $0 on ", scalar(localtime), "\n\n\n";



foreach my $ip ( Ipblock->retrieve_all() ){
    next if $ip->address =~ /^127\.0\.0/;
    next unless ( $ip->prefix == 32 || $ip->prefix == 128);
    my ($type, $site, $entity);
    
    if ( $ip->interface->device ){
	my $address = $ip->address;
	if ( $ip->interface->device->productname &&
	     $ip->interface->device->productname->type){
	    $type = $ip->interface->device->productname->type->name;
	    if (exists $types{$type}){
		$type = $types{$type};
	    }else{
		$type = "host";
	    }
	}else{
	    $type = 'host';
	    warn "Can't figure out type for Device with ip $address" if $DEBUG;
	}
	if ( $ip->interface->device->site ){
	    my $s = $ip->interface->device->site;
	    $site = $s->name;
	    $site = join '_', split /\s+/, $site;
	}else{
	    $site = 'unknown';
	    warn "Can't determine site for Device with ip $address" if $DEBUG;
	}
	if ( $ip->interface->device->used_by ){
	    my $e = $ip->interface->device->used_by;
	    $entity = $e->name;
	    $entity = join '_', split /\s+/, $entity;
	    $entities{$entity}{id} = $e->id;
	}else{
	    $entity = 'unknown';
	    $entities{$entity}{id} = 0;
	    warn "Can't determine entity for Device with ip $address" if $DEBUG;
	}
    }else{
	warn "Can't determine Device from ip ", $ip->address;
	next;
    }
    
    my $name;
    unless ( ($name = &resolve($ip->address)) && !exists $name2ip{$name} ){
	$name = $ip->interface->device->name 
	    . "-" . $ip->interface->name
	    . "-" . $ip->address;
	warn "Assigned name $name \n" if $DEBUG;
    }
    $name2ip{$name} = $ip->id;
    $ip2name{$ip->id} = $name;
    $hosts{$ip->address}{type} = $type;
    $hosts{$ip->address}{name} = $name;
    push @{ $entities{$entity}{site}{$site}{hosts} }, $ip->address;
    
}

# Now that we have all the names
foreach my $ipid ( keys %ip2name ){
    
    my $ipobj = Ipblock->retrieve($ipid);
    
    my $parentlist =  join ',', map { $ip2name{$_} } 
    map { ($_->ips)[0] }  map { $_->parent }  $ipobj->interface->parents;
    
    if ($parentlist){
	$hosts{$ipobj->address}{parents} = $parentlist;
    }else{
	$hosts{$ipobj->address}{parents} = "NULL"
	}
    
}


foreach my $entity ( sort keys %entities ){
    
    print "############################################################################################################################\n";
    print "network               $entity                      NULL\n";
    print "############################################################################################################################\n";
    
    print "\n";
    
    if ( my $entobj = Entity->retrieve($entities{$entity}{id}) ){
	foreach my $subnet ($entobj->used_blocks){
	    print "prefix                 ", $subnet->address, "/", $subnet->prefix, "\n";
	}
    }
    
    print "\n";
    
    foreach my $site ( sort keys %{$entities{$entity}{site}} ){
	my $oldhandle = select FILE;
	$~ = "HOSTLIST";
	select ($oldhandle);
	
	print "building               $site\n";
	foreach my $ipadd (sort @{$entities{$entity}{site}{$site}{hosts}} ){
	    
	    # Define a format for the host list
	    
	    format HOSTLIST = 
@<<<<<<<<<<<<<<<<<<<<<<@<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<@<<<<<<<<<<<<<<<<<<<@<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$hosts{$ipadd}{type}, $hosts{$ipadd}{name}, $ipadd, $hosts{$ipadd}{parents}
.
            write ;
        }

        $oldhandle = select FILE;
        $~ = "FILE";
        select ($oldhandle);

        print "\n";
    }
}


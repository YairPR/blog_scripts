#!/usr/bin/env perl
#
# Author: Bertrand Drouvot
# Visit my blog : http://bdrouvot.wordpress.com/
# V1.0 (2016/01)
#
# Description:
# Utility used to display dnfs metrics in real time per snap or per average since the collection began.
# It basically takes a snapshot each second (default interval) of the gv$dnfs_stats view and computes the delta
# with the previous snapshot.
# You have to set oraenv on one DB instance
# The utility is RAC aware
# No need to be multitenant aware as con_id=0 into gv$dnfs_stats for 12.1 in any cases even if pdbs are created
# You can choose the number of snapshots to display and the time to wait between snapshots.
#
# Usage:
# ./db_io_dnfs_metrics.pl -help
#
# Chek for new version : http://bdrouvot.wordpress.com/db_io_dnfs_metrics_script/
#
#----------------------------------------------------------------#

BEGIN {
    die "ORACLE_HOME not set\n" unless $ENV{ORACLE_HOME};
    unless ($ENV{OrAcLePeRl}) {
       $ENV{OrAcLePeRl} = "$ENV{ORACLE_HOME}/perl";
       $ENV{PERL5LIB} = "$ENV{PERL5LIB}:$ENV{OrAcLePeRl}/lib:$ENV{OrAcLePeRl}/lib/site_perl";
       $ENV{LD_LIBRARY_PATH} = "$ENV{LD_LIBRARY_PATH}:$ENV{ORACLE_HOME}/lib32:$ENV{ORACLE_HOME}/lib";
       exec "$ENV{OrAcLePeRl}/bin/perl", $0, @ARGV;
    }
}

use strict;
use DBI;
use DBD::Oracle qw(:ora_session_modes);

use Getopt::Long; 

our %options; 
our $debug=0;
our $version;
our $sub_version;
our $nb_pdbs=0;
our $interval=1; 
our $count=999999;
our $showinst=0;
our $rac=0;
our $inst_type='RDBMS';
our $dbh;
our $instpattern='all';
our $show_pattern='inst';
our $display_pattern='snap';
our $instid_pattern='inst_id';
our $sqlsuffixe;
our $sql1;
our $main_sql='';
our %instances;
our %showinstances=();
our %sql_patterns;
our %diffsnaps;
our %avgdiffsnaps=();
our %rtvalues;
our %pkeys;
our $bkey;
our @ekey;
our %ckeys=();
our @array_of_ckeys_description=();
our @array_of_display_keys=();
our @array_of_ckey=();
our @delta_fields;
our $global_sql_pattern='';
our @array_of_report_header;
our $report_format_values;
our @report_fields_values;
our $seconds;
our $minuts;
our $hours;
our @since_timing;
our %sort_fields;
our $sort_field_pattern='';
our $global_group_by_pattern='';

sub main {
&get_the_options(@ARGV);

	$instid_pattern="inst_id";
	my $ckey_cpt=0;	
	&connect_db;
	$version=check_version();
	$sub_version=check_sub_version();
	if ($sub_version =~ m/^notok$/i ){
        print "\n\n ERROR : You must connect to a database instance version >= 11.2.0.4\n\n";
	exit 1;
	} 

	if ($version >= 12) {$nb_pdbs=check_pdbs()};
	
	$sort_fields{1}='READS';
	$sort_fields{2}='WRITES';
	$sort_fields{6}='NONE';
	$sort_fields{3}='IOPS';
	%sort_fields = reverse %sort_fields;
	if (!$sort_field_pattern) {$sort_field_pattern='NONE'};
        $main_sql="
        select inst_id,sum(NFS_READ),sum(NFS_WRITE),sum(NFS_READ+NFS_WRITE) as IOPS,sum(NFS_READBYTES)/1024,sum(NFS_WRITEBYTES)/1024,$interval as interval,sum(NFS_READBYTES+NFS_WRITEBYTES)/1024/1024 from gv\$dnfs_stats where 1=1
	";
        $global_group_by_pattern=" group by inst_id";
        $pkeys{0}='%30s';
	# What need to be show
        my @show_fields = split (/,/,$show_pattern);
        foreach my $show (@show_fields) {
	if ($show =~ m/^inst$/i ){ 
	# group by instance
	$array_of_ckeys_description[$ckey_cpt]{0}='%30s'; 	
	$array_of_ckeys_description[$ckey_cpt]{6}='%10s';
	$array_of_display_keys[$ckey_cpt]{0}='y'; 
	$array_of_display_keys[$ckey_cpt]{6}='y';
	$ckey_cpt=$ckey_cpt+1; 
	}
	}
        	
        @delta_fields=(1,2,3,4,5,7);
        $report_format_values="%02d:%02d:%02d %1s %-10s %1s %-7.0f %1s %-7.0f %1s %-7.0f %1s %-8.0f %1s %-7.0f %1s %-8.0f %1s %-8.0f %1s %-8.1f\n";
	@report_fields_values=("1/6","4/6","4*1024/1","2/6","5/6","5*1024/2","3","7/6");

	@array_of_report_header=(["%02d:%02d:%02d %24s %-7s %1s %-7s %12s %-7s %1s %-7s\n",'','Kby','','AvgBy/','','Kby','','AvgBy/'],["%02d:%02d:%02d %1s %-10s %1s %-7s %1s %-7s %1s %-7s %1s %-8s %1s %-7s %1s %-8s %1s %-8s %1s %-8s\n",'','INST','','Reads/s','','Read/s','','Read','','Writes/s','','Write/s','','Write','','IOPS','','MB/s'],["%02d:%02d:%02d %1s %-10s %1s %-7s %1s %-7s %1s %-7s %1s %-8s %1s %-7s %1s %-8s %1s %-8s %1s %-8s\n",'','----------','','-------','','-------','','-------','','--------','','-------','','--------','','--------','','--------']);
        &go_sql_real_time;
}

#
# Ctrl+C signal
#
$SIG{INT}= \&close;

sub close {
        print "Disconnecting from RDBMS...\n";
        $sql1->finish;
        $dbh->disconnect();
        exit 0;
}

sub get_the_options {
    my $help; 
    GetOptions('help|h' => \$help,
		'interval=i'=>\$interval,
		'count=i'=>\$count,
		'inst:s' => \$instpattern,
		'sort_field:s' => \$sort_field_pattern,
		'display:s' => \$display_pattern,
		'show:s' => \$show_pattern) or &usage();

    &usage() if ($help); 
}

sub go_sql_real_time {
&connect_db;
&check_instance_type($inst_type);
&check_rac;
&build_instances;
&build_rac_pattern;
&build_glob_sql_pattern;
&build_glob_sql;
&initialise_arrays;
&launch_loop;
}

sub connect_db {
$dbh = DBI->connect('dbi:Oracle:',"", "", { ora_session_mode => ORA_SYSDBA });
}
 
sub check_instance_type {
my $inst_type=$_[0];
debug("Instance Type: ".$inst_type);
my $sql1 = $dbh->prepare('select value from v$parameter where name=\'instance_type\' ');
$sql1->execute;

if ( $sql1->fetchrow_array =~ /$inst_type/i) {
        $sql1->finish;
}
else {
        print "\n\n ERROR : You must connect to a ".$inst_type." instance \n\n";
        $sql1->finish;
        $dbh->disconnect();
        exit 1;
}
}

sub check_rac {
my $sql1 = $dbh->prepare('select value  from v$parameter where name = \'cluster_database\'');
$sql1->execute;
if ( $sql1->fetchrow_array =~ /true/i) {
   $rac=1;
}
$sql1->finish;
}

sub check_version {
my $sql1 = $dbh->prepare('select regexp_replace(version,\'\..*\') from v$instance');
$sql1->execute;
return ($sql1->fetchrow_array);
$sql1->finish;
}

sub check_sub_version {
my $sql1 = $dbh->prepare('select case when substr( b.banner, instr(b.banner, \'Release \')+8, instr(substr(b.banner,instr(b.banner,\'Release \')+8),\' \') ) >= \'11.2.0.4\' then \'ok\' else \'notok\' end
from 
(
select replace(banner,\'9.\',\'09.\') banner
    from
        v$version
    where rownum = 1
) b');
$sql1->execute;
return ($sql1->fetchrow_array);
$sql1->finish;
}


sub check_pdbs {
my $sql1 = $dbh->prepare('select count(*) from v$pdbs');
$sql1->execute;
return ($sql1->fetchrow_array);
$sql1->finish;
}

sub build_instances {
my $sql1 = $dbh->prepare('select inst_id,instance_name, host_name from gv$instance');
$sql1->execute;
while ( my ($instid, $instname,$host) = $sql1->fetchrow_array) {
        $instances{$instname} = $instid;
}
$sql1->finish;
}

sub build_in_pattern {
 my $pattern=shift;
 my $column=shift;
 my %list_of_field=@_; 
 my %reverse_list_of_field = reverse %list_of_field;
 my @fields = split (/,/,$pattern);
 my $output_in_pattern=''; 	
 foreach my $field (@fields) {
        if (!exists  $reverse_list_of_field{uc($field)}) {
         print "\n\n ERROR : $field $column is not found !! \n";
         exit 1;
	} else {
	if (!$output_in_pattern) {
	$output_in_pattern=" and $column in ('"."$reverse_list_of_field{uc($field)}'";
	} else {
	$output_in_pattern=$output_in_pattern.",'$reverse_list_of_field{uc($field)}'";
	}
	}
 }
	($output_in_pattern)?$output_in_pattern=$output_in_pattern.")":"";
	return $output_in_pattern;
}

sub build_rac_pattern
{
if ($rac & ! ($instpattern =~ /all|current/i)) {
        my @fields = split (/,/,$instpattern);

        foreach my $instname (@fields) {

        if (!exists  $instances{uc($instname)}) {
              print "\n\n ERROR : The instance $instname is not found !! \n";
              $dbh->disconnect();
              exit 1;
        } else {
           $showinstances{$instname}=$instances{$instname};;
        }
        }
}

# If not rac put pattern as current

if (! $rac) {
$instpattern = 'current';
}

if ($instpattern =~ /current/i) {

my $sql1_sql = "select inst_id,instance_name, host_name from gv\$instance where inst_id = userenv('instance')";

my $sql1 = $dbh->prepare($sql1_sql);
$sql1->execute;
while ( my ($instid, $instname,$host) = $sql1->fetchrow_array) {
        $instances{$instname} = $instid;
}
$sql1->finish;
}

if (($rac & ($instpattern =~ /all|current/i)) | (! $rac & ($instpattern =~ /current/i))) {
        %showinstances = %instances;
}

# RAC : Create the SQL suffixe based on the instances to request on

# Case 1 : The current instance or list of instances
$sqlsuffixe = ((! $rac)  | ($rac & $instpattern =~ /current/i) ? " and ".$instid_pattern. " = userenv('instance')" : "");

# Case 2 : All the instances
# Nothing to do

if ($rac & ! ($instpattern =~ /all|current/i)) {

        foreach my $inst (keys %showinstances) {

        my $inst_id = $showinstances{$inst};

        if ($sqlsuffixe) {
        $sqlsuffixe = $sqlsuffixe." or ".$instid_pattern. " = $inst_id";
                }
        else
                {
        $sqlsuffixe = $sqlsuffixe." and (".$instid_pattern. " = $inst_id";
                }
        }
        $sqlsuffixe = $sqlsuffixe.")";

}
debug("sqlsuffixe: ".$sqlsuffixe);
# Reverse the hash for display usage (Report Section)
%showinstances = reverse %showinstances;
}

sub build_glob_sql_pattern {

	foreach my $column (keys %sql_patterns) {
	debug("column: ".$column);
	debug("pattern: ".$sql_patterns{$column});
	if ($sql_patterns{$column}) {$global_sql_pattern = $global_sql_pattern." and ".$column." like '".$sql_patterns{$column}."' "}
	}
	debug("global_sql_pattern: ".$global_sql_pattern);
}

sub build_glob_sql {
	$main_sql = $main_sql.$global_sql_pattern.$sqlsuffixe.$global_group_by_pattern; 
	debug("Main sql: ".$main_sql);
}

sub build_the_key {
	my @tab1 = @_;
	$bkey='';
	@ekey=();
	foreach my $id (sort { $a <=> $b }(keys %pkeys)) {
	if ($bkey) {$bkey = $bkey.".".$pkeys{$id}};
	if (!$bkey) {$bkey = $pkeys{$id}};
	push(@ekey,$tab1[$id]);
	}
}

sub build_compute_key {
        my @tab1 = @_;
 	for my $i ( 0 .. $#array_of_ckeys_description ) {
        	my $bckey='';
        	my @eckey=();
    		for my $j ( sort { $a <=> $b } (keys %{ $array_of_ckeys_description[$i] }) ) {
		($bckey)?($bckey = $bckey.".".$array_of_ckeys_description[$i]{$j}):($bckey = $array_of_ckeys_description[$i]{$j});
		push(@eckey,$tab1[$j]);
    		}
	my $ckey = sprintf($bckey,@eckey);
	$array_of_ckey[$i]=$ckey;
	}	
}

sub initialise_arrays { 
	$sql1 = $dbh->prepare($main_sql);
	my $key;
	$sql1->execute;
	while ( my @tab1 = $sql1->fetchrow_array) {
	&build_the_key(@tab1); 
	$key = sprintf($bkey,@ekey);
	@{$rtvalues{$key}}=@tab1;
	@{$diffsnaps{$key}}=@tab1;
	debug("key is : ".$key);
	}
}

sub launch_loop {
	my $key;
	my $ckey;
	my $cpt=0;
	for (my $nb=0;$nb < $count;$nb++) {
	print "............................\n";
	print "Collecting $interval sec....\n";
	print "............................\n";
	sleep $interval;
	$sql1->execute;
	($seconds, $minuts, $hours) = localtime(time);

	# Keep the first timing for the average section
        ($cpt==0)?(@since_timing=($hours,$minuts,$seconds)):"";

	# Empty diffsnaps
	%diffsnaps = ();
	while ( my @tab1 = $sql1->fetchrow_array) {
	&build_the_key(@tab1);
	$key = sprintf($bkey,@ekey);

	# Build the compute key

	&build_compute_key(@tab1);

	# Initialise non delta fields
	for (my $tabid=0;$tabid < scalar(@tab1);$tabid++) {
 	for my $i ( 0 .. $#array_of_ckeys_description ) {
	my $ckey=$array_of_ckey[$i];
	$diffsnaps{$ckey}->[$tabid]=($array_of_display_keys[$i]{$tabid}?"$tab1[$tabid]":"") unless (grep (/^$tabid$/,@delta_fields));
	$avgdiffsnaps{$ckey}->[$tabid]=($array_of_display_keys[$i]{$tabid}?"$tab1[$tabid]":"") unless (grep (/^$tabid$/,@delta_fields));
	debug("Non delta fields: for display_keys $array_of_display_keys[$i]{$tabid} and tabid $tabid ".$diffsnaps{$ckey}->[$tabid]);
	}
	}
 
	# get the list of delta fields
        foreach my $deltaid (@delta_fields) {
 	for my $i ( 0 .. $#array_of_ckeys_description ) {
	my $ckey=$array_of_ckey[$i];
        debug("deltaid : ".$deltaid);
        debug("key is : ".$key);
        debug("ckey during diff is : ".$ckey);
        $diffsnaps{$ckey}->[$deltaid] = $diffsnaps{$ckey}->[$deltaid] + $tab1[$deltaid] - $rtvalues{$key}->[$deltaid];
        debug("Previous : ".$rtvalues{$key}->[$deltaid]);
        debug("Current : ".$tab1[$deltaid]);
        debug("Diff is : ".$diffsnaps{$ckey}->[$deltaid]);
	}
        }
        @{$rtvalues{$key}} = @tab1;
        debug("key is : ".$key);
        debug("ckey is : ".$ckey);
        }	

        # compute the average since the collection began
       
	foreach my $deltaid (@delta_fields) {
	foreach my $diffkey  (keys %diffsnaps){
	$avgdiffsnaps{$diffkey}->[$deltaid] = (($avgdiffsnaps{$diffkey}->[$deltaid] * $cpt) + $diffsnaps{$diffkey}->[$deltaid]) / ($cpt+1); 
	} 
	}
	$cpt=$cpt+1;
	# Report now for snaps
	(grep (/snap/i,$display_pattern))?(print "\n"):"";
	(grep (/snap/i,$display_pattern))?(print "......... SNAP TAKEN AT ...................\n"):"";
	(grep (/snap/i,$display_pattern))?(print "\n"):"";
	(grep (/snap/i,$display_pattern))?(&report_header("snap",@array_of_report_header)):"";
	(grep (/snap/i,$display_pattern))?(&report_values("snap",%diffsnaps)):"";
	# Report now for average
	(grep (/avg/i,$display_pattern))?(print "\n"):"";
	(grep (/avg/i,$display_pattern))?(print "......... AVERAGE SINCE ...................\n"):"";
	(grep (/avg/i,$display_pattern))?(print "\n"):"";
	(grep (/avg/i,$display_pattern))?(&report_header("avg",@array_of_report_header)):"";
	(grep (/avg/i,$display_pattern))?(&report_values("avg",%avgdiffsnaps)):"";
	}
}

sub report_header {
	my $display_date = shift;
	my @array_of_report_header = @_;
	foreach my $report_ligne (0..@array_of_report_header-1) {
		my @header;
		@header = ($display_date eq "avg")?(@since_timing):($hours,$minuts,$seconds);
		foreach my $report_column (1..@{$array_of_report_header[$report_ligne]}) {
	        push(@header,$array_of_report_header[$report_ligne][$report_column]);
		}
		printf ($array_of_report_header[$report_ligne][0],@header);
	}
}

sub report_resultset {

	my $display_date = shift;
	my $pk=shift;
	my %resultset=@_;
	my $backup_mult;

	my @values; 
	@values = ($display_date eq "avg")?(@since_timing):($hours,$minuts,$seconds);

	if (%showinstances) {push(@values,'',$showinstances{$resultset{$pk}->[0]})};

	foreach my $id (@report_fields_values) {

	push(@values,'');

	my @need_div=split(/\//,$id);
	my @need_mult=split(/\*/,$id);

	if (@need_mult > 1) {
	$need_mult[1] =~ s/\/.*//;
	$backup_mult = $resultset{$pk}->[$need_mult[0]];
	$resultset{$pk}->[$need_mult[0]] = ($resultset{$pk}->[$need_mult[0]]) * $need_mult[1];
	debug("Mult is needed for id : ".$id);
	debug("Mult[0] is : ".$need_mult[0]);
	debug("Mult[1] is : ".$need_mult[1]);
	} 

	if (@need_div > 1) {
	$need_div[0] =~ s/\*.*//;
	debug("Div is needed for id : ".$id);
	debug("needed_div is : ".@need_div);
	debug("div[0] is : ".$need_div[0]);
	debug("div[1] is : ".$need_div[1]);
	if ($resultset{$pk}->[$need_div[1]] > 0) {push(@values,$resultset{$pk}->[$need_div[0]]/$resultset{$pk}->[$need_div[1]])};
	if ($resultset{$pk}->[$need_div[1]] == 0) {push(@values,0)};
	}
	else
	{
	push(@values,$resultset{$pk}->[$id]);
	}
	# In case the resultset has been changed, then put the value back (For the average..)
	if (@need_mult > 1) {
        $resultset{$pk}->[$need_mult[0]] = $backup_mult;
	}	
	}
	printf ($report_format_values,@values);
}

sub report_values {
	my $nb =1;
	my %resultset = ();
	my $display_date = shift;
	my %display_what = @_;
	my $rank = 1;
	my %ranked_instances = ();

	# rank the instance based on the sort field

	foreach my $pk (sort {$display_what{$b}[$sort_fields{uc($sort_field_pattern)}] <=> $display_what{$a}[$sort_fields{uc($sort_field_pattern)}] || $display_what{$a}[0] <=> $display_what{$b}[0]} (keys(%display_what))) {

	if (!(exists $ranked_instances{$display_what{$pk}[0]})) {
	$ranked_instances{$display_what{$pk}[0]}=$rank;
	$display_what{$pk}->[99] = $rank;
	$rank++;
	} else {
	$display_what{$pk}->[99] = $ranked_instances{$display_what{$pk}[0]};
	}
	debug("Rank is ".$display_what{$pk}->[99]." for instance ".$display_what{$pk}[0]);
	}

	if ($nb_pdbs == 0) {

	foreach my $pk (sort {$display_what{$a}[99] <=> $display_what{$b}[99] || $display_what{$b}[$sort_fields{uc($sort_field_pattern)}] <=> $display_what{$a}[$sort_fields{uc($sort_field_pattern)}] || $display_what{$a}[1] cmp $display_what{$b}[1] || $display_what{$a}[3] cmp $display_what{$b}[3] || $display_what{$a}[10] cmp $display_what{$b}[10]} (keys(%display_what))) {
	&report_resultset($display_date,$pk,%display_what);
	debug("Sorted value is : ".$display_what{$pk}[$sort_fields{uc($sort_field_pattern)}]);
	}
	} else {
	foreach my $pk (sort {$display_what{$a}[99] <=> $display_what{$b}[99] || $display_what{$b}[$sort_fields{uc($sort_field_pattern)}] <=> $display_what{$a}[$sort_fields{uc($sort_field_pattern)}] || $display_what{$a}[1] cmp $display_what{$b}[1] || $display_what{$a}[2] cmp $display_what{$b}[2] || $display_what{$a}[4] cmp $display_what{$b}[4] || $display_what{$a}[11] cmp $display_what{$b}[11]} (keys(%display_what))) {
	&report_resultset($display_date,$pk,%display_what);
	debug("Sorted value is : ".$display_what{$pk}[$sort_fields{uc($sort_field_pattern)}]);
	}
	}
}


sub usage {
&usage_dnfs_metrics();
}


sub usage_dnfs_metrics {

&connect_db;
	
print " \nUsage: $0 [-interval] [-count] [-inst] [-display] [-sort_field] [-help]\n";
print "\n";
print " Default Interval : 1 second.\n";
print " Default Count    : Unlimited\n\n";
printf ("  %-15s   %-65s %-10s \n",'Parameter','Comment','Default');
printf ("  %-15s   %-65s %-10s \n",'---------','-------','-------');
printf ("  %-15s   %-65s %-10s \n",'-INST=','ALL - Show all Instance(s) ','ALL');
printf ("  %-15s   %-65s %-10s \n",'','CURRENT - Show Current Instance ','');
printf ("  %-15s   %-65s %-10s \n",'-DISPLAY=','What to display: snap,avg (comma separated list)','SNAP');
printf ("  %-15s   %-65s %-10s \n",'-SORT_FIELD=','reads|writes|iops','NONE');
print ("\n");
print ("Example: $0 \n");
print ("Example: $0  -inst=BDT_1\n");
print ("Example: $0  -sort_field=reads\n");
print "\n\n";
exit 1;
}

sub debug {
    if ($debug==1) {
        print $_[0]."\n";
    }
}


&main(@ARGV);

#!/usr/perl5/5.8.4/bin/perl -w
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#
# Copyright (c) 2011 Joyent, Inc.
#
# ziostat - report I/O statistics per zone
#
# USAGE:    ziostat [-hIMr] [interval [count]]
#           -h              # help
#           -I              # print results per interval (where applicable)
#	    -M              # print results in MB/s
#	    -r		    # print data in comma-separated format
#
#   eg,	    ziostat               # print summary since zone boot
#           ziostat 1             # print continually every 1 second
#           ziostat 1 5           # print 5 times, every 1 second
#           ziostat -M 1          # print results in MB/s, every 1 second
#
# NOTES:
#
# - The calculations and output fields emulate those from iostat(1M) as closely
#   as possible.  When only one zone is actively performing disk I/O, the
#   results from iostat(1M) in the global zone and ziostat in the local zone
#   should be almost identical.
#
# - As with iostat(1M), a result of 100% for disk utilization does not mean that
#   the disk is fully saturated.  Instead, that measurement just shows that at
#   least one operation was pending over the last quanta of time examined.
#   Since disk devices can process more than one operation concurrently, this
#   measurement will frequently be 100% but the disk can still offer higher
#   performance.
#
# - This script is based on Brendan Gregg's K9Toolkit examples:
#
#	http://www.brendangregg.com/k9toolkit.html
#

use Getopt::Std;
use Sun::Solaris::Kstat;
my $Kstat = Sun::Solaris::Kstat->new();

# Process command line args
usage() if defined $ARGV[0] and $ARGV[0] eq "--help";
getopts('hIMr') or usage();
usage() if defined $main::opt_h;

my $USE_MB = defined $main::opt_M ? $main::opt_M : 0;
my $USE_INTERVAL = defined $main::opt_I ? $main::opt_I : 0;
my $USE_COMMA = defined $main::opt_r ? $main::opt_r : 0;

chomp(my $zname = (`/sbin/zonename`));

my ($interval, $count);
if ( defined($ARGV[0]) ) {
	$interval = $ARGV[0];
	$count = defined ($ARGV[1]) ? $ARGV[1] : 2**32;
	usage() if ($interval == 0);
} else {
	$interval = 1;
	$count = 1; 
}

$main::opt_h = 0;

my $HEADER_FMT = $USE_COMMA ?
     "r/%s,w/%s,%sr/%s,%sw/%s,wait,actv,wsvc_t,asvc_t,%%w,%%b,zone\n" :
     "    r/%s    w/%s   %sr/%s   %sw/%s wait actv wsvc_t asvc_t  " .
     "%%w  %%b zone\n";
my $DATA_FMT = $USE_COMMA ?
    "%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%d,%d,%s\n" :
    " %6.1f %6.1f %6.1f %6.1f %4.1f %4.1f %6.1f %6.1f %3d %3d %s\n";

my $BYTES_PREFIX = $USE_MB ? "M" : "k";
my $BYTES_DIVISOR = $USE_MB ? 1024 * 1024 : 1024;
my $INTERVAL_SUFFIX = $USE_INTERVAL ? "i" : "s";

my $Modules = $Kstat->{'zone_io'};

my $old_wlentime = 0;
my $old_wtime = 0;
my $old_rlentime = 0;
my $old_rtime = 0;
my $old_rbytes = 0;
my $old_wbytes = 0;
my $old_rops = 0;
my $old_wops = 0;
my $old_snaptime = 0;

my $ii = 0;
$Kstat->update();

while (1) {
	printf($HEADER_FMT, $INTERVAL_SUFFIX, $INTERVAL_SUFFIX, $BYTES_PREFIX,
	    $INTERVAL_SUFFIX, $BYTES_PREFIX, $INTERVAL_SUFFIX);

	foreach my $instance (sort keys(%$Modules)) {
		my $Instances = $Modules->{$instance};
	
		foreach my $name (keys(%$Instances)) {
			$Stats = $Instances->{$name};

			if ($name eq $zname) {
				print_stats();
			}
		}
	}
	
	$ii++;
	if ($ii == $count) {
		exit (0);
	}

	sleep ($interval);
	$Kstat->update();
}

sub print_stats {
	my $wlentime = $Stats->{'wlentime'};
	my $wtime = $Stats->{'wtime'};
	my $rlentime = $Stats->{'rlentime'};
	my $rtime = $Stats->{'rtime'};

	my $rbytes = $Stats->{'nread'};
	my $wbytes = $Stats->{'nwritten'};
	my $rops = $Stats->{'reads'};
	my $wops = $Stats->{'writes'};

	my $etime = $Stats->{'snaptime'} -
	    ($old_snaptime > 0 ? $old_snaptime : $Stats->{'crtime'});

	# Calculate basic statistics
	my $rate_divisor = $USE_INTERVAL ? 1 : $etime;
	my $reads = ($rops - $old_rops) / $rate_divisor;
	my $writes = ($wops - $old_wops) / $rate_divisor;
	my $nread = ($rbytes - $old_rbytes) / $rate_divisor / $BYTES_DIVISOR;
	my $nwritten = ($wbytes - $old_wbytes) / $rate_divisor / $BYTES_DIVISOR;

	# Calculate overall transactions per second
	my $tps = ($rops + $wops - $old_rops - $old_wops) / $etime;

	# Calculate average length of wait and run queues
	my $wait = ($wlentime - $old_wlentime) / $etime;
	my $actv = ($rlentime - $old_rlentime) / $etime;

	# Calculate average wait and run times
	my $wsvc = $tps > 0 ? $wait * (1000 / $tps) : 0.0;
	my $asvc = $tps > 0 ? $actv * (1000 / $tps) : 0.0;

	# Calculate the % time the wait queue and disk are active
	my $w_pct = (($wtime - $old_wtime) / $etime) * 100;
	my $b_pct = (($rtime - $old_rtime) / $etime) * 100;

	printf($DATA_FMT,
	    $reads,
	    $writes,
	    $nread,
	    $nwritten,
	    $wait,
	    $actv,
	    $wsvc,
	    $asvc,
	    $w_pct,
	    $b_pct,
	    $zname);

	# Save current calculations for next loop
	$old_wlentime = $wlentime;
	$old_wtime = $wtime;
	$old_rlentime = $rlentime;
	$old_rtime = $rtime;
	$old_rbytes = $rbytes;
	$old_wbytes = $wbytes;
	$old_rops = $rops;
	$old_wops = $wops;
	$old_snaptime = $Stats->{'snaptime'};
}

sub usage {
        print STDERR <<END;
USAGE: ziostat [-hIMr] [interval [count]]
   eg, ziostat               # print summary since zone boot
       ziostat 1             # print continually every 1 second
       ziostat 1 5           # print 5 times, every 1 second
       ziostat -I            # print results per interval (where applicable)
       ziostat -M            # print results in MB/s
       ziostat -r            # print results in comma-separated format
END
        exit 1;
}

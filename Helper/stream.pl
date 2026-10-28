# Runs inside /usr/bin/perl so MediaRemote treats the process as an Apple binary.
use strict;
use warnings;
use DynaLoader;

my ($lib) = @ARGV;
die "usage: stream.pl <dylib>\n" unless $lib;
my $handle = DynaLoader::dl_load_file($lib, 0) or die "cannot load $lib\n";
my $sym = DynaLoader::dl_find_symbol($handle, "dynamicnotch_stream") or die "no symbol\n";
my $xs = DynaLoader::dl_install_xsub("main::dynamicnotch_stream", $sym);
&$xs();

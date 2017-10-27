#!/usr/bin/perl
use strict;
use warnings;
use POSIX qw/strftime WIFEXITED WEXITSTATUS/;
use File::Path;
use File::Copy;
use Sys::Hostname;
use FindBin;
use File::Temp qw/tempfile/;

our $VERSION = 3.2;

### start of config

# these are the defaults,
# looks for config file in:
# wherever/this/script/is/backup.cfg
# $HOME/.backup.cfg
# /etc/backup.cfg
# does not fail if it cannot find any config file
# cfg file format is usual ini
# section names are forced uppercase
# keys in the GLOBAL (the default) section are forced uppercase

our %DEFAULTS = (
	KEEP => 10, # how many backups to keep locally
	S3KEEP => 10, # how many backups to keep on s3
	ROOTDIR => '/var/www/', # these must have a terminating slash!
	BACKUPDIR => '/backup/store/',
	UPPREPDIR => '/backup/up/',
	DBUSER => '',
	DBPASS => '',
	DBHOST => 'localhost',
	S3CMD => '/usr/bin/s3cmd',
	S3BUCKET => '',
	S3BUCKET_OFFSITE => '',
	S3CMDCFG => '/backup/.s3cfg',
	GPGMODE => 'symmetric',
	GPGPASS => '',
	GPGRECIPIENT => '',
	MYSQLDUMPOPTS => '',
	# if the percentage of size difference between latest backup
	# and the one before that is larger than this value, warn in the email
	BACKUP_SIZE_DIFF_PERCENT => 30,

	# docrootname => sqldbname (you can specify more than one, separated by whitespace)
	# if sqldbname == undef, wont try to dump sql and will dump docrootname as an absolute path
	DIRS => {
	#	'prod' => 'prod_db ppsomeotherdb',
	#	'dev' => 'dev_db',
	#	'/etc' => undef,
	},
	OFFSITES => {
	#	'prod' => 1,
	},
	# keys are emails, values mean if an email is on or off
	MAILTO => {
	#	'someone@example.com' => 1,
	},
	EXCLUDE_FROM_TAR => {
	#	'absolute path' => 1,
	},
);

our %O;

### end of config

our @MAILTEXT;

sub config_override_from_env {
	my $c = shift;

	for my $k (keys %$c) {
		next if ref $c->{$k};

		my $ek = "BACKUP_CFG_OVERRIDE_$k";
		$c->{$k} = $ENV{ $ek } if $ENV{ $ek };
	}
}

sub get_config {
	my %config = @_;

	my @cfg_paths = (
		$FindBin::Bin.'/backup.cfg',
		$ENV{HOME}.'/.backup.cfg',
		'/etc/backup.cfg',
	);

	unshift @cfg_paths, $ENV{BACKUP_CFG} if $ENV{BACKUP_CFG};

	my ($file) = grep { -r $_ } @cfg_paths;

	unless ($file) {
		config_override_from_env(\%config);
		return %config;
	}

	open my $fh, '<', $file or die "cannot open cfg file: $file: $!\n";

	my $section = 'GLOBAL';

	my $line = 0;
	while (<$fh>) {
		$line++;
		next if m/^\s*#/;
		next if m/^\s*$/;
		if (my ($s) = m/^\s*\[([^]]+)\]\s*$/) {
			$section = uc $s;
			next;
		}
		if (my ($k, $v) = m/^\s*(\S+)\s*=\s*(.*)/) {
			$v =~ s/\s+$//;
			($section eq 'GLOBAL' ? $config{uc $k} : $config{uc $section}{$k}) = $v;
			next;
		}
		die "failed in cfg $file:$line on $_\n";
	}

	config_override_from_env(\%config);

	if ($ENV{DEBUG_BACKUP}) {
		require Data::Dumper;
		die Data::Dumper::Dumper(\%config);
	}

	# sanity checking...
	for (qw(ROOTDIR BACKUPDIR UPPREPDIR)) {
		die "bad config: $_ = $config{$_} must have a terminating slash\n" unless substr($config{$_}, -1) eq '/';
		die "bad config: $_ = $config{$_} is not a directory\n" unless -d $config{$_};
	}

	die "bad config: no dirs to back up?\n" unless %{ $config{DIRS} };

	# this line turns both undef and empty string into an empty array!
	# it also lets us support multiple databases for a webroot
	$_ = [ split ] for values %{ $config{DIRS} };

	for (keys %{ $config{DIRS} }) {
		if (@{ $config{DIRS}{$_} }) {
			die "bad config: [DIRS] $config{ROOTDIR}$_ is not a directory\n" unless -d $config{ROOTDIR}.$_;
		}
		else {
			die "bad config: [DIRS] $_ is not a directory\n" unless -d $_;
		}
	}
	if (grep { $_ } values %{ $config{OFFSITES} }) {
		die "bad config: s3cfg $config{S3CMDCFG} does not exist\n" unless -f $config{S3CMDCFG};
		if ($config{GPGMODE} eq 'symmetric') {
			die "bad config: no gpg pass set\n" if $config{GPGPASS} eq '';
		}
		elsif ($config{GPGMODE} eq 'asymmetric') {
			die "bad config: no gpg recipient set\n" if $config{GPGRECIPIENT} eq '';
		}
		else {
			die "bad config: unknown gpg mode: $config{GPGMODE}\n";
		}
	}

	die "bad config: s3cmd not found at $config{S3CMD}\n" unless -f $config{S3CMD} && -x $config{S3CMD};

	$config{EXCLUDE_FROM_TAR} = [ keys %{ $config{EXCLUDE_FROM_TAR} || {} } ];

	if ($ENV{DEBUG_BACKUP} && $ENV{DEBUG_BACKUP} eq 'late') {
		require Data::Dumper;
		die Data::Dumper::Dumper(\%config);
	}

	%config;
}

sub send_mail {
	my ($subject, $body, @to) = @_;
	open my $m, '|-', '/usr/bin/mailx', '-n', '-s', $subject, @to or die "cannot fork mailx: $!";
	print $m $body;
	close $m;
}

sub gather_info {
	my ($title) = @_;
	my %du = du($O{BACKUPDIR});
	my @l;
	push @l, "files locally:";
	push @l, map { sprintf "%5s - %s", $du{$_}, $_ } sort keys %du;
	push @l, 'files on s3:';
	push @l, s3cmd('rels');
	("$title", "filesystem usage:", df(), @l);
}

sub df {
	my $df = qx(df -h);
}

sub du {
	my ($path) = @_;
	open my $du, '-|', '/usr/bin/find', $path, '-type', 'f', '-exec', 'du', '-h', '{}', '+' or die "cannot fork du: $!";
	my %du;
	while (<$du>) {
		chomp;
		my ($size, $p) = split /\t/, $_, 2;
		$p =~ s{^$path/?}{};
		$du{$p} = $size;
	}
	%du;
}

sub du_sum {
	my ($path) = @_;
	$path = quotemeta($path);
	my $du = qx(du -sk $path);
	(split /\s+/, $du)[0];
}

sub is_latest_backup_suspicious {
	opendir my $d, $O{BACKUPDIR} or die "cannot open ".$O{BACKUPDIR}.": $!";
	my ($latest, $previous) = reverse sort grep { !m/^\.|\.\.$/ } readdir $d;
	closedir $d;

	if ($latest && $previous) {
		my $latest_size = du_sum($O{BACKUPDIR}.$latest);
		my $previous_size = du_sum($O{BACKUPDIR}.$previous);

		my $diff = ($O{BACKUP_SIZE_DIFF_PERCENT}/100) * $previous_size;

		if (abs($latest_size - $previous_size) > $diff) {
			return (
				latest_path => $latest,
				latest_size => $latest_size,
				previous_path => $previous,
				previous_size => $previous_size,
				ltgt => ($latest_size > $previous_size ? 'larger' : 'smaller'),
			);
		}
		return ();
	}
	return ();
}

sub tar {
	my ($tarfile, $srcdir) = @_;

	my $exclude_opts = '';
	if ($O{EXCLUDE_FROM_TAR} && @{ $O{EXCLUDE_FROM_TAR} }) {
		$exclude_opts = join ' ', map '--exclude='._shell_quote_backend($_), @{ $O{EXCLUDE_FROM_TAR} };
	}

	open my $tar, '-|', "/bin/tar $exclude_opts -cz --ignore-failed-read -f $tarfile $srcdir 2>&1" or die "cannot fork tar: $!";
	my @errors;
	while (<$tar>) {
		if (!m/Removing leading .* from member names/) {
			push @errors, $_;
		}
	}
	close($tar) or die "tar failed: $?\n", join('', @errors);
}

sub dump_sql {
	my ($target, $source, $dbhost, $dbname) = @_;
	unless ($dbname) {
		return;
	}
	system(sprintf '/usr/bin/mysqldump -u"%s" '.($O{DBPASS} eq '' ? '' : '-p"%s"').' -h"%s" "%s" | /bin/gzip -c > "%s/%s/%s.sql.gz"',
		$O{MYSQLDUMPOPTS}, $O{DBUSER}, ($O{DBPASS} eq '' ? () : $O{DBPASS}), $O{DBHOST}, quotemeta($dbname), $O{BACKUPDIR}.$target, $source, quotemeta($dbname)) == 0
			or die "cannot excute mysqldump: $!";
}

my $warned_about_missing_s3;
sub s3cmd {
	my $opts = @_ && ref $_[0] eq 'HASH'
		? shift
		: {};

	$opts->{BUCKET} ||= $O{S3BUCKET};

	my ($cmd, @args) = @_;
	my ($process, @call);

	if ($opts->{BUCKET} eq '' || $O{S3CMDCFG} eq '' || !-f $O{S3CMDCFG}) {
		if (grep { $_ } values %{ $O{OFFSITES} }) {
			warn "S3BUCKET or S3CMDCFG are not configured properly, will not do S3 calls\n" unless $warned_about_missing_s3;
			$warned_about_missing_s3 = 1;
		}
		return;
	}

	my $source = sprintf 's3://%s/%s', $opts->{BUCKET}, (@args && $args[0] ? $args[0] : '');
	shift @args;
	my $bucket = quotemeta 's3://'.$opts->{BUCKET}.'/';

	if ($cmd eq 'ls') {
		$process = sub {
			my (undef, $file) = split /$bucket/, shift, 2;
			$file ? $file : ();
		};
		@call = ('ls', $source);
	}
	elsif ($cmd eq 'rels') {
		$process = sub {
			my ($date, $time, $size, $path) = split /\s+/, $_, 4;
			$path =~ s/$bucket//;
			$path ? sprintf("%5s - %s", $size, $path) : ();
		};
		@call = ('ls', $source, '-H', '--recursive');
	}
	elsif ($cmd eq 'get') {
		$process = sub { print $_[0], "\n" if $_[0] };
		@call = ('get', $source);
	}
	elsif ($cmd eq 'del') {
		@call = ('del', $source, @args);
		$process = sub {};
	}
	else {
		die "bad s3 command: $cmd";
	}
	open my $s3, '-|', $O{S3CMD}, '-c', $O{S3CMDCFG}, @call or die "cannot fork s3cmd: $!";
	my @out;
	while (<$s3>) {
		chomp;
		push @out, $process->($_);
	}
	return @out;
}

sub encrypt {
	my ($source_filename, $target_filename) = @_;

	if ($O{GPGMODE} eq 'symmetric') {
		system(sprintf '/bin/echo "%s"|/usr/bin/gpg --force-mdc --batch -q --passphrase-fd 0 -o "%s/%s.gpg" -c "%s/%s"',
			$O{GPGPASS}, $O{UPPREPDIR}, $source_filename, $O{BACKUPDIR}, $target_filename) == 0
			or die "cannot execute gpg (or the shell?): $! (exit code: $?)";
	}
	else {
		system('/usr/bin/gpg', '--output', "$O{UPPREPDIR}/$source_filename.gpg", '--batch', '--encrypt', '--recipient', $O{GPGRECIPIENT}, "$O{BACKUPDIR}/$target_filename") == 0
			or die "cannot execute gpg: $! (exit code: $?)";
	}
}

sub encrypt_and_upload {
	my ($target, $source, $source_filename) = @_;

	encrypt $source_filename, "$target/$source/$source_filename";

	my $s3filepath = "$target/$source";
	$s3filepath =~ s{^/+|/+$}{}g;
	$s3filepath =~ s{/+}{/}g;

	my @target_buckets = $O{S3BUCKET};
	push @target_buckets, $O{S3BUCKET_OFFSITE} if $O{S3BUCKET_OFFSITE};

	for my $tbucket (@target_buckets) {
		system(sprintf '%s --progress --force -c "%s" put "%s/%s" "s3://%s/%s/"',
			$O{S3CMD}, $O{S3CMDCFG}, $O{UPPREPDIR}, $source_filename.'.gpg', $tbucket, $s3filepath) == 0
			or die "cannot execute s3cmd when uploading to $tbucket: $! (exit code: $?)";
	}

	unlink $O{UPPREPDIR}.$source_filename.'.gpg';
}

sub clean_up {
	my $dir = shift;
	rmtree $dir, { keep_root => 1 };
}

sub upload {
	my ($target, $source, $dbnames) = @_;

	clean_up $O{UPPREPDIR};

	my @filenames = map "$_.sql.gz", @$dbnames;
	push @filenames, "docroot.tar.gz";


	for (@filenames) {
		encrypt_and_upload $target, $source, $_;
	}
}

sub gpg_unpack {
	my ($file) = @_;
	(my $outfile = $file) =~ s/\.gpg$//;
	if ($file eq $outfile) {
		$outfile .= '.decoded';
	}
	system(sprintf '/bin/echo "%s"|/usr/bin/gpg --passphrase-fd 0 -d "%s" > %s', $O{GPGPASS}, $file, $outfile) == 0
		or die "cannot gpg unpack: $!";
	unlink $file;
}

sub do_backup {
	my ($target, $source) = @_;

	die "file alredy exists, something is bogus" if -e $O{BACKUPDIR}."$target/$source";

	push @MAILTEXT, "backing up $source";

	mkpath $O{BACKUPDIR}."$target/$source" or die "cannot mkpath $O{BACKUPDIR}$target/$source: $!";

	my $srcdir = '';
	if (@{ $O{DIRS}{$source} }) { # the dir to be backed up has an associated database table. this means the dir is relative to ROOTDIR
		$srcdir .= $O{ROOTDIR};
	}
	$srcdir .= $source;

	tar sprintf('%s%s/%s/docroot.tar.gz', $O{BACKUPDIR}, $target, $source), $srcdir;
	for my $dbname (@{ $O{DIRS}{$source} }) {
		dump_sql $target, $source, $O{DBHOST}, $dbname;
	}

	if (defined $O{OFFSITES}{$source}) {
		push @MAILTEXT, " uploading $source";
		upload $target, $source, $O{DIRS}{$source};
	}
}

sub delete_old {
	my ($backuproot) = @_;

	opendir my $d, $backuproot or die "cannot open $backuproot: $!";
	my @files = reverse sort grep { !m/^\.|\.\.$/ } readdir $d;
	closedir $d;
	# newest are at the top now
	if ( @files > $O{KEEP} ) {
		for ( my $i = $O{KEEP}; $i < @files; ++$i ) {
			rmtree $backuproot.$files[$i];
		}
	}

	delete_old_s3($O{S3KEEP}, {}, reverse sort(s3cmd('ls')));

	if ($O{S3BUCKET_OFFSITE}) {
		my $s3opt = { BUCKET => $O{S3BUCKET_OFFSITE} };
		delete_old_s3(1, $s3opt, reverse sort(s3cmd($s3opt, 'ls')));
	}
}

sub delete_old_s3 {
	my ($keep_n, $s3cmdopt, @files) = @_;

	# never delete backups made on the first of the month
	@files = grep { !m{^\d{6}01\d{6}/?$} } @files;

	if (@files > $keep_n) {
		for ( my $i = $keep_n; $i < @files; ++$i ) {
			s3cmd $s3cmdopt, 'del', $files[$i], '--recursive';
		}
	}
}

my %cmd;
my %help;

$help{help} = "this help";
$cmd{help} = sub {
	print "$0 v$VERSION\n";
	print "will do backup if no args are passed!\n";
	print "commands:\n";
	for my $cmd (sort keys %cmd) {
		my $help = $help{$cmd} || '';
		$help = "- $help" if $help;

		printf "  %-20s %s\n", $cmd, $help;
	}
};

$help{ls} = "get list of files in our s3 bucket";
$cmd{ls} = sub { print "$_\n" for s3cmd @_ };

$help{get} = "get a file from our s3 bucket";
$cmd{get} = sub {
	my (undef, $path) = @_;
	print "getting ", $path, " from s3\n";
	s3cmd 'get', $path;
	my $local_file = (split qr{/}, $path)[-1];
	if (! -f $local_file) {
		die "cannot gpg-unpack file, does not exist: $local_file";
	}
	if ($O{GPGMODE} eq 'symmetric') {
		print "unpacking...\n";
		gpg_unpack $local_file;
	}
	else {
		print "NOT unpacking, it was encrypted using a keypair\n";
	}
	print "done\n";
};

$help{check_update} = "check this script against the master in the repo, optionally update";
$cmd{check_update} = sub {
	my ($cmd, $yes) = @_;
	$yes ||= '';

	my (undef, $fn) = tempfile UNLINK => 1;

	system('wget', '-q', 'https://raw.github.com/nws/backup.pl/master/backup.pl', '-O', $fn) == 0
		or die "cannot exec wget: $!";

	my $rv = system("diff", '-u', $0, $fn);

	my $identical = WIFEXITED($rv) && WEXITSTATUS($rv) == 0;

	return if $identical;

	if (lc $yes eq 'yes') {
		copy $fn, $0
			or die "cannot update $0: $!";
		print "\n\n-- updated\n";
	}
	else {
		print "\n\n-- remote file is different, to update local copy, run:\n--  $0 $cmd yes\n";
	}
};

my %noconfig_commands = (
	help => 1,
	check_update => 1,
);

if (@ARGV) {
	my $cmd = shift @ARGV;
	$cmd = 'help' unless defined $cmd{$cmd};
	%O = get_config(%DEFAULTS) unless $noconfig_commands{$cmd};
	$cmd{$cmd}->($cmd, @ARGV);
}
else {
	%O = get_config(%DEFAULTS);

	my $timestamp = strftime('%Y-%m-%d %H:%M %z', localtime);
	my $subject = "Backup on ".hostname." at $timestamp";
	@MAILTEXT = ($subject, '');

	eval {
		die "cannot find backup dir ".$O{BACKUPDIR} unless -d $O{BACKUPDIR};
		die "cannot find rootdir ".$O{ROOTDIR} unless -d $O{ROOTDIR};

		my $bsubdir = strftime "%Y%m%d%H%M%S", localtime;

		die "file alredy exists, something is bogus" if -e $O{BACKUPDIR}.$bsubdir;

		push @MAILTEXT, gather_info('State before backup'), '';

		mkdir $O{BACKUPDIR}.$bsubdir or die "cannot mkdir: $!";

		push @MAILTEXT, "Backing up to $bsubdir/";

		for my $source (keys %{ $O{DIRS} }) {
			do_backup $bsubdir, $source;
		}
		delete_old $O{BACKUPDIR};

		push @MAILTEXT, '', gather_info('State after backup'), '';
	};
	if ($@) {
		push @MAILTEXT, "FAILED: ".$@;
		$subject = 'FAILED: '.$subject;
	}
	else {
		my %diff = is_latest_backup_suspicious();
		if (%diff) {
			$subject = 'WARNING: '.$subject;
			unshift @MAILTEXT, (
				"WARNING: Latest backup ($diff{latest_path}, $diff{latest_size}K) is more than ".$O{BACKUP_SIZE_DIFF_PERCENT}."% $diff{ltgt} than the previous one ($diff{previous_path}, $diff{previous_size}K).",
				'',
			);
		}
		else {
			$subject = 'SUCCESS: '.$subject;
		}
	}
	if (grep { $_ } values %{ $O{MAILTO} }) {
		send_mail $subject, join("\n", @MAILTEXT), grep { $O{MAILTO}{$_} } keys %{ $O{MAILTO} };
	}
	else {
		print "ERRORS (no email addresses configured, just dumping it):\n";
		print " $_\n" for @MAILTEXT;
	}
}

sub _shell_quote_backend {
	my @in = @_;

	return '' unless @in;

	my $ret = '';
	my $saw_non_equal = 0;
	foreach (@in) {
		if (!defined $_ or $_ eq '') {
			$_ = "''";
			next;
		}

		my $escape = 0;

		# = needs quoting when it's the first element (or part of a
		# series of such elements), as in command position it's a
		# program-local environment setting

		if (/=/) {
			if (!$saw_non_equal) {
				$escape = 1;
			}
		}
		else {
			$saw_non_equal = 1;
		}

		if (m|[^\w!%+,\-./:=@^]|) {
			$escape = 1;
		}

		if ($escape || (!$saw_non_equal && m/=/)) {
			# ' -> '\''
			s/'/'\\''/g;

			# make multiple ' in a row look simpler
			# '\'''\'''\'' -> '"'''"'
			s|((?:'\\''){2,})|q{'"} . (q{'} x (length($1) / 4)) . q{"'}|ge;

			$_ = "'$_'";
			s/^''//;
			s/''$//;
		}
	}
	continue {
		$ret .= "$_ ";
	}

	chop $ret;
	return $ret;
}

=pod

TODO:
* add support for percona's xtrabackup
* do not run w/o args
* verbosity with interactive terminal

=cut

=head1 COPYRIGHT & LICENSE

 Copyright 2011-2013 NWS

  This program is free software; you can redistribute it and/or modify
  it under the terms of the MIT License.

=cut

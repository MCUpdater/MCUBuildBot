#!/usr/bin/perl -w
use strict;
use feature "state";
use Config::IniFiles;
use File::Basename;
use IO::CaptureOutput qw{:all};
use List::MoreUtils qw{any none};
use LWP::UserAgent;
use Net::SFTP::Foreign;
use Scalar::Util qw(looks_like_number);
use String::Util 'trim';
use Switch;
use POE;
use POE::Component::IRC;
use POE::Component::IRC::Plugin::Console;
use POE::Component::IRC::Plugin::NickServID;
use POE::Component::IRC::Plugin::BotAddressed;
use POE::Component::IRC::Plugin::Logger;
use WWW::Google::URLShortener;
use DBI;

my $cfg = new Config::IniFiles( -file => '/opt/MCU-build/config.ini');
my $google_api = $cfg->val('General','GoogleAPI');
my $shortener = WWW::Google::URLShortener->new($google_api);
my $ua = new LWP::UserAgent;
my $botdir = $cfg->val('Paths', 'BotHome');
my $basedir = $cfg->val('Paths', 'Workspace');
# Color contants
my $WHITE = "\x0300";
my $BLACK = "\x0301";
my $BLUE = "\x0302";
my $GREEN = "\x0303";
my $RED = "\x0304";
my $BROWN = "\x0305";
my $PURPLE = "\x0306";
my $ORANGE = "\x0307";
my $YELLOW = "\x0308";
my $LIGHT_GREEN = "\x0309";
my $TEAL = "\x0310";
my $LIGHT_CYAN = "\x0311";
my $LIGHT_BLUE = "\x0312";
my $PINK = "\x0313";
my $GREY = "\x0314";
my $LIGHT_GREY = "\x0315";
my $NORMAL = "\x0f";

my $dbDriver = $cfg->val('Database','Driver');
my $dbSpecific = $cfg->val('Database','Specific');
my $dbUser = $cfg->val('Database','User');
my $dbPass = $cfg->val('Database','Password');
my $dbh = DBI->connect("dbi:$dbDriver:$dbSpecific", $dbUser, $dbPass) or die "Can't connect: $DBI::errstr";
my @branches = ('master','develop');
my @ops = ('smbarbour','allaryin');
my $active = 0;
$dbh->do('CREATE TABLE IF NOT EXISTS Builds(branch PRIMARY KEY, gitcommit, buildnumber)');
my $updateBuild = $dbh->prepare('REPLACE INTO Builds(branch, gitcommit, buildnumber) VALUES (?, ?, ?)');
my $getLastBuild = $dbh->prepare('SELECT gitcommit, buildnumber FROM Builds where branch = ?');

my $topic = "";

my ($irc) = POE::Component::IRC->spawn();

POE::Session->create(
		inline_states => {
		_start => \&bot_start,
		irc_001 => \&on_connect,
		irc_public => \&on_public,
		irc_msg => \&on_private,
		irc_join => \&on_join,
		irc_disconnected => \&on_disconnect,
		irc_332 => \&on_topicResponse,
		irc_topic => \&on_topicChange,
		git_poll => \&Poll,
		},
		);

sub bot_start {
	my $kernel = $_[KERNEL];
	$irc->yield(register => "all");
	my $nick = $cfg->val("IRC","Nick");
	$irc->yield(connect => {
			Nick => $nick,
			Username => $cfg->val("IRC", "Username"),
			Ircname => $cfg->val("IRC", "Ircname"),
			Server => $cfg->val("IRC", "Server"),
			Port => $cfg->val("IRC", "Port"),
			}
		   );

	$irc->plugin_add( 'NickServID', POE::Component::IRC::Plugin::NickServID->new( Password => $cfg->val("IRC","NickServPass") ));
	$kernel->delay(git_poll => 10);
	$irc->yield(topic => "#MCUpdater");
}

sub on_connect {
	$irc->yield(join => $cfg->val("IRC","Channel"));
	return;
}

sub on_disconnect {
	if ($active == 1) {
		&bot_start;
	}
	return;
}

sub on_topicChange {
	my ($kernel, $who, $where, $what) = @_[KERNEL, ARG0, ARG1, ARG2];
	$topic = $what;
	print qq{Topic in $where is now "$topic" changed by $who.\n};
}

sub on_topicResponse {
	my ($kernel, $chan, $top) = @_[KERNEL, ARG0, ARG1];
	$topic = substr($top,index($top,":")+1,255);
	print "Topic is: $topic\n";
}

sub on_public {
	my ($kernel, $who, $where, $msg) = @_[KERNEL, ARG0, ARG1, ARG2];
	my $nick = (split /!/, $who)[0];
	my $channel = $where->[0];
	my $isOp = 0;
	foreach (@ops) {
		if ( $nick eq $_ ) { $isOp = 1; }
	}
	if ($msg =~ /^\!/) {
		my ($command, @cmdargs) = (split / /, $msg);
		switch ($command)
		{
			case '!build' {
				if ($isOp != 1) {
					$irc->yield(privmsg => $channel, "You are not allowed to do that.");
				} else {
					my ($branch, $force, $overrideNum) = @cmdargs[0, 1, 2];
					if (none { /$branch/ } @branches) {
						$irc->yield(privmsg => $channel, "Branch $branch is not configured for build.");
						return;
					}
					my $noChange = 0;
					chdir("$basedir$branch/MCUpdater");
					open(PULL, 'git pull origin |');
					my $pullOutput = "";
					while(<PULL>){
						$pullOutput .= $_ . "\n";
#$irc->yield(privmsg => $channel, $_);
					}
					close(PULL);
					if (index($pullOutput, "Already up-to-date") != -1) {
						$noChange = 1;
					}
					if ($noChange == 1 && $force ne "force") {
						$irc->yield(privmsg => $channel, "No changes to be built on branch $branch.");
						return;
					} else {
						$irc->yield(privmsg => $channel, "Beginning build on branch $branch.");
					}
					&DoBuild($channel, $branch, $force, $overrideNum);
				}
			}
			case /\!l(c$|astcommit$)/ {
				my @localbranches = @cmdargs;
				if (@localbranches == 0) { @localbranches = @branches; }
				foreach my $branch (@localbranches) {
					if (none { /$branch/ } @branches) {
						$irc->yield(privmsg => $channel, "Branch $branch is not configured.");
					} else {
						chdir("$basedir$branch/MCUpdater");
						my $response = `git log -1 --format="format:%H~~~~~%cn~~~~~%s"`;
						my ($commit, $author, $title) = split('~~~~~',$response);
						$irc->yield(privmsg => $channel, "Last commit on branch $branch:");
						$irc->yield(privmsg => $channel, &ShortenCommit($commit) . " <$author> $title");
					}
				}
			}
			case /\!c($|ommits$)/ {
				my $branch = $cmdargs[0];
				if (none { /$branch/ } @branches) {
					$irc->yield(privmsg => $channel, "Branch $branch is not configured.");
					return;
				}
				my $count = $cmdargs[1];
				if (!defined $count) {
					$count = 3;
				}
				if (looks_like_number($count)) {
					open(GIT, qq{git log -$count --format="format:%H~~~~~%cn~~~~~%s" |});
					my @lines = <GIT>;
					close(GIT);
					$irc->yield(privmsg => $channel, "Last $count commit(s) on branch $branch:");
					foreach my $line (@lines) {
						my ($commit, $author, $title) = split('~~~~~',$line);
						$irc->yield(privmsg => $channel, &ShortenCommit($commit) . " <$author> $title");
					}
				} else {
					$irc->yield(privmsg => $channel, "$count is not a number.");
				}
			}
		}
	}
	print "<$nick> $msg\n";
	return;
}

sub on_private {
	my ($kernel, $from, $to, $msg, $identified) = @_[KERNEL, ARG0, ARG1, ARG2, ARG3];
	my $nick = (split /!/, $from)[0];
	my ($command, @cmdargs) = (split / /, $msg);
	my $isOp = 0;
	foreach (@ops) {
		if ( $nick eq $_ ) { $isOp = 1; }
	}
	if ($command eq "shutdown" && $isOp == 1) {
		$active = 0;
		$irc->yield(quit => "Shutting down.");
		$irc->delay(git_poll => undef);
		$irc->yield(shutdown => "");
	}
	return;
}

sub on_join {
	return;
}

sub Poll {
	my $kernel = $_[KERNEL];
	&CheckBranch('master');
	&CheckBranch('develop');
	$kernel->delay(git_poll => 300);
}

sub CheckBranch {
	my $branch = $_[0];
	my $channel = "#MCUpdater";
	my $noChange = 1;
	chdir("$basedir$branch/MCUpdater");
	open(PULL, 'git pull origin |');
	my $pullOutput = "";
	while(<PULL>){
		$pullOutput .= $_ . "\n";
	}
	close(PULL);
	if (index($pullOutput, "Already up-to-date") == -1 && $pullOutput ne "") {
		$noChange = 0;
	} else {
		print "No changes for branch: $branch\n";
	}
	if ($noChange == 0) {
		$irc->yield(privmsg => $channel, "Beginning build on branch $branch.");
	} else {
		return;
	}
	&DoBuild($channel, $branch);
	return;
}

sub DoBuild {
	my ($channel, $branch, $force, $overrideNum) = @_[0,1,2,3];
	$getLastBuild->execute($branch);
	my $result = $getLastBuild->fetch;
	my $buildNum = 1;
	my $commit = "";
	if (defined $result) {
		$commit = $$result[0];
		$buildNum = $$result[1];
		$buildNum++;
	}
	if (defined $overrideNum) { $buildNum = $overrideNum; }
	my $newCommit = `git log -1 --format=format:%H`;
	$irc->yield(privmsg => $channel, "Newest commit on branch $branch: $newCommit");
	my $logcmd;
	if ($commit eq "") {
		$logcmd = qq{git log -5 --format="format:%H~~~~~%cn~~~~~%s" |};
	} else {
		$logcmd = qq{git log $commit..$newCommit --format="format:%H~~~~~%cn~~~~~%s" |};
	}
	open (CHANGES, $logcmd);
	my @changes = <CHANGES>;
	print "Lines: " . @changes . "\n";
	close(CHANGES);
	foreach my $change (@changes) {
		my ($commit, $author, $title) = split('~~~~~',$change);
		$irc->yield(privmsg => $channel, &ShortenCommit($commit) . " <$author> $title");
	}
	$ENV{BUILD_NUMBER}=$buildNum;
	$ENV{GIT_BRANCH}=$branch;
	$ENV{GIT_COMMIT}=$newCommit;
	my @build_args = qw{ant -f build-client.xml};
	my ($combined, $success, $exit) = capture_exec_combined(@build_args);
	open(BUILD, ">>", qq{$botdir/logs/build-log.txt});
	print BUILD qq{Build ($branch $buildNum) successful=$success ($exit)\n$combined\n};
	close(BUILD);
	if ($success) {
		my @build_args = qw{ant -f build-serverutility.xml};
		my ($combined, $success, $exit) = capture_exec_combined(@build_args);
		open(BUILD, ">>", qq{$botdir/logs/build-log.txt});
		print BUILD qq{Build ($branch $buildNum) successful=$success ($exit)\n$combined\n};
		close(BUILD);
		if ($success) {
			$irc->yield(privmsg => $channel, $GREEN . "Build $buildNum successful on branch $branch" . $NORMAL);
			$updateBuild->execute($branch, $newCommit, $buildNum);
			my $sftp = Net::SFTP::Foreign->new('northumberland.dreamhost.com', user => 'mcujenkins', key_path => "$botdir/id_mcujenkins", ssh_cmd => '/usr/bin/ssh');
			$sftp->error and $irc->yield(privmsg => $channel, "Unable to establish SFTP connection: " . $sftp->error);
			my @files = glob "dist/*";
			foreach my $file (@files) {
				open FILE, $file;
				binmode FILE;
				my $shortname = basename($file);
			$sftp->setcwd("/home/mcujenkins/files.mcupdater.com/$branch/");
				$sftp->put(\*FILE,$shortname);
				close FILE;
				$sftp->setcwd("/home/mcujenkins/files.mcupdater.com/");
				if ($shortname =~ /MCUpdater/) {
					if ($branch eq 'master') {
						$sftp->remove('MCUpdater-recommended.jar');
						$sftp->symlink('MCUpdater-recommended.jar', "$branch/$shortname");
					} else {
						$sftp->remove('MCUpdater-latest.jar');
						$sftp->symlink('MCUpdater-latest.jar', "$branch/$shortname");
					}
					my $shorturl = $shortener->shorten_url("http://files.mcupdater.com/$branch/$shortname");
					my @elements = split(/\s\|\s/, $topic);
					for (my $x = 0; $x < @elements; $x++) {
						print $elements[$x] . "\n";
						if (substr($elements[$x],0,14) eq 'Latest release' && $branch eq 'master') {
							$elements[$x] = "Latest release: $shorturl";
						} elsif (substr($elements[$x],0,10) eq 'Latest dev' && $branch eq 'develop') {
							$elements[$x] = "Latest dev: $shorturl";
						}
					}
					$topic = join(' | ', @elements);
					$irc->yield(topic => $channel, $topic);
				}
			}
		} else {
			$irc->yield(privmsg => $channel, $RED . "ServerUtility build failed on branch $branch" . $NORMAL);
		}
	} else {
		$irc->yield(privmsg => $channel, $RED . "Client build failed on branch $branch" . $NORMAL);
	}
	return;
}

sub ShortenCommit {
	my $commit = $_[0];
	my $response = $ua->post("http://git.io", {url=>"https://github.com/MCUpdater/MCUpdater/commit/$commit",});
	return $response->header("Location");
}

$active = 1;
$poe_kernel->run();
exit 0;

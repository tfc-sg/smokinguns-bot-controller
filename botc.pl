#!/usr/bin/env perl
# Version: 1.0.76
# Revision: 76
# Released: 2026-10-29
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use POSIX qw(strftime);
use Time::HiRes qw(sleep);
use Time::Local qw(timelocal);

# Smoking Guns / Quake 3 random map and bot controller via RCON.
# Example:
#   perl smokinguns_map_bot_controller.pl --host 127.0.0.1 --debug

my %opt = (
    host               => '127.0.0.1',
    port               => undef,
    password           => undef,
    rcon_config_file   => '/usr/local/games/smokinguns_ballerbude/rcon.cfg',
    botskill_config_file => '/usr/local/games/smokinguns_ballerbude/botskills.cfg',
    debug              => 1,
    map_history_file   => 'smokinguns_map_history.csv',
    database_config_file => '/usr/local/games/smokinguns_ballerbude/database.cfg',
    database_host      => '127.0.0.1',
    database_port      => 3306,
    database_name      => 'b3',
    database_user      => 'b3',
    game_log_file      => '/usr/local/games/smokinguns_ballerbude/ballerbude_game.log',
    console_log_file   => '/usr/local/games/smokinguns_ballerbude/ballerbude_console.log',
    command_file       => '/usr/local/games/smokinguns_ballerbude/botc_commands.log',
    once               => 0,
    poll_seconds       => 5,
    map_load_wait_ms   => 3000,
    min_players        => 3,    # target total: human players + bots
    max_players        => 20,   # sv_maxclients includes humans and bots
    max_bots           => 8,
    min_botplayer      => 3,    # Minimum managed bots before human reduction.
    human_bot_reduction_threshold => 2,
    fraglimit          => 25,
    timelimit_minutes  => 15,
    custom_vote_min_humans => 2,
    custom_vote_seconds => 30,
    # Each command has its own authorized GUID list. An empty list allows
    # that command for every player. GUIDs are matched case-insensitively.
    command_admin_guids => {
        help           => [],
        info           => [],
        version        => [],
        status         => [],
        rotationstatus => [],
        botstatus      => [],
        ping           => [],
        showmaps       => [],
        showbots       => [],
        lastonline     => [],
        statistic      => [],
        xlrstats       => [],
        top10          => [],
        rotation1      => [],
        rotation2      => [],
        rotation3      => [],
        rotation4      => [],
        rotation5      => [],
        rotation6      => [],
        startrotation  => [],
        nextmap        => [],
        map            => [],
        setbots        => [],
        botseasy       => [],
        botsmedium     => [],
        botshard       => [],
        botsrandom     => [],
        botsprofile    => [],
        botskill       => [],
        yes            => [],
        no             => [],
    },
);
my $CONTROLLER_VERSION = 'unknown';
if (open my $source, '<', __FILE__) {
    while (my $line = <$source>) {
        if ($line =~ /^# Version:\s*(\S+)/) {
            $CONTROLLER_VERSION = $1;
            last;
        }
    }
    close $source;
}

my %cli_rcon_option;
while (@ARGV) {
    my $arg = shift @ARGV;
    if ($arg eq '--debug') { $opt{debug} = 1; }
    elsif ($arg eq '--once') { $opt{once} = 1; }
    elsif ($arg =~ /^--(host|port|password|rcon-config-file|poll-seconds|map-load-wait-ms|min-players|max-players|max-bots|min-botplayer|human-bot-reduction-threshold|fraglimit|timelimit-minutes|map-history-file|game-log-file|console-log-file|command-file)$/) {
        my $key = $1;
        die "Missing value for $arg\n" unless @ARGV;
        $key =~ s/-/_/g;
        $opt{$key} = shift @ARGV;
        $cli_rcon_option{$key} = 1 if $key eq 'port' || $key eq 'password';
    }
    elsif ($arg eq '--help') {
        print <<'HELP';
Usage:
  perl smokinguns_map_bot_controller.pl [options]

Options:
  --host ADDRESS             RCON host (default: 127.0.0.1)
  --port PORT                RCON port (overrides rcon.cfg)
  --password PASSWORD        server rconpassword (overrides rcon.cfg)
  --rcon-config-file FILE    RCON configuration file (default: /usr/local/games/smokinguns_ballerbude/rcon.cfg)
  --min-players N            target human players + bots (default: 3)
  --max-players N            sv_maxclients limit (default: 20)
  --max-bots N               maximum managed bots (default: 8)
  --min-botplayer N          minimum managed bots (default: 3)
  --human-bot-reduction-threshold N  reduce bots above this human count (default: 2)
  --fraglimit N              per-map frag limit (default: 25)
  --timelimit-minutes N      per-map time limit (default: 15)
  --map-history-file FILE    CSV map start/end history
  --game-log-file FILE       server log used to detect nextmap votes
  --console-log-file FILE    console log containing "Vote passed"
  --command-file FILE        trusted SSH panel command inbox
  --poll-seconds N           polling interval in seconds (default: 5)
  --map-load-wait-ms N       wait after map command in milliseconds (default: 3000)
  --debug                    print RCON commands and decisions
  --once                     configure the current map once, then exit
HELP
        exit 0;
    }
    else { die "Unknown option: $arg (use --help for help)\n"; }
}

sub read_rcon_config {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot read RCON configuration $file: $!\n";
    my %config;
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ m{^(?:#|//|;)};

        # Supported formats: port = 27961, password = secret,
        # set net_port 27961, and seta rconpassword "secret".
        if ($line =~ /^(?:set|seta|sets)\s+(?:net_)?port\s+"?(\d+)"?\s*$/i
            || $line =~ /^(?:rcon_)?port\s*=\s*"?(\d+)"?\s*$/i) {
            $config{port} = $1;
        }
        elsif ($line =~ /^(?:set|seta|sets)\s+rconpassword\s+"?(.+?)"?\s*$/i
            || $line =~ /^(?:rcon_)?password\s*=\s*"?(.+?)"?\s*$/i) {
            my $password = $1;
            $password =~ s/^"|"$//g;
            $config{password} = $password;
        }
    }
    close $fh;
    return \%config;
}

my $rcon_config = read_rcon_config($opt{rcon_config_file});
$opt{port} = $rcon_config->{port} unless $cli_rcon_option{port};
$opt{password} = $rcon_config->{password} unless $cli_rcon_option{password};

die "No RCON port found in $opt{rcon_config_file}\n" unless defined $opt{port} && $opt{port} =~ /^\d+$/;
die "--password is required\n" unless length $opt{password};
die "max-players must be at least 1\n" unless $opt{max_players} >= 1;
die "min-players cannot exceed max-players\n" if $opt{min_players} > $opt{max_players};
$opt{min_botplayer} = 0 if $opt{min_botplayer} < 0;
$opt{min_botplayer} = $opt{max_bots} if $opt{min_botplayer} > $opt{max_bots};
$opt{human_bot_reduction_threshold} = 0 if $opt{human_bot_reduction_threshold} < 0;

# Maps supplied by the user. Individual map settings can be overridden in
# %MAP_OVERRIDE, for example:
#   dm_mine => { min_players => 4, max_bots => 4, fraglimit => 40, timelimit_minutes => 20 },
my @MAPS_ROTATION1 = qw(
    dm_hangemhigh dm_dry dm_fort dm_canyon br_mexico
    dm_tillian dm_newtown br_cobber dm_sancuchillo dm_nonamecity
    dm_mine dm_train dm_alamo_2 br_durango br_santacruz
    br_santaclare br_elpaso br_farm br_clayborn dm_dawnfort
    dm_steamboat dm_coyotebluff dm_backwater dm_harbor dm_lago
    dm_pueblomuerto dm_station dm_lake dm_tijuana dm_ttstation
    dm_aguacaliente dm_darkfort dm_deadwood dm_ghosttown dm_mulpris
    dm_5gent-w dm_wsand-w dm_gstallion-w dm_xtown-w dm_sweetwater
);

my @MAPS_ROTATION2 = qw(
    dm_warehouse_mini dm_littletownV1 dm_knivefun dm_Xmas
    dm_tinydesert br_haunted dm_simpson12 dm_los_amigos
);

my @MAPS_ROTATION3 = qw(
    br_hangemhigh br_train br_tijuana br_lago br_alamo_2 br_deadwood
    br_ghosttown br_harbor br_nonamecity br_cobber br_durango br_elpaso
    br_farm br_mexico br_santacruz br_clayborn br_santaclare br_xtown
    br_simpson12 br_haunted br_villa br_tombstone12 br_sanjuanico
    br_deathvalleymine br_comanchecanyon br_dry
);

my @MAPS_ROTATION4 = qw(
    du_highnoon du_showdown du_arena
);

my @MAPS_ROTATION5 = qw(
    dm_highnoon_time_station dm_highnoon_deja_vu dm_highnoon_cuatro_niveles
    dm_highnoon_southern_villa dm_highnoon_desert_runes dm_highnoon_corrida_de_toro
    dm_highnoon_villa_courtyard dm_highnoon_churchyard
);

my @MAPS_ROTATION6 = qw(
    dm_showdown_canyon dm_showdown_churchyard dm_showdown_ecstasy_of_gold
    dm_showdown_emptystreet dm_showdown_indian_village dm_showdown_mexican_city
    dm_showdown_southern_manor dm_showdown_town_gallows
);

my %ROTATIONS = (
    rotation1 => \@MAPS_ROTATION1,
    rotation2 => \@MAPS_ROTATION2,
    rotation3 => \@MAPS_ROTATION3,
    rotation4 => \@MAPS_ROTATION4,
    rotation5 => \@MAPS_ROTATION5,
    rotation6 => \@MAPS_ROTATION6,
);
my %ROTATION_GAME_TYPES = (
    rotation1 => 0, # Deathmatch
    rotation2 => 0, # Deathmatch
    rotation3 => 5, # Bank Robbery
    rotation4 => 1, # Duel
    rotation5 => 0, # Deathmatch
    rotation6 => 0, # Deathmatch
);
my $active_rotation = 'rotation1';

my %MAP_OVERRIDE = (
    # Example: dm_mine => { min_players => 3, max_players => 10, max_bots => 4, fraglimit => 30, timelimit_minutes => 12 },
);

# All bot profiles are loaded from botskills.cfg. Each entry contains the
# internal character, visible colored name, profile skill, team, and delay.
my @BOTS;
my $current_map_started_at;
my $game_log_position;
my $command_file_position;
my $panel_request_id;
my $console_log_position;
my $nextmap_vote_active = 0;
my $vote_target_map;
my $awaiting_vote_map_switch = 0;
my $scheduled_next_map;
my $last_map;
my $next_change_at;
my $bot_skill_mode = 'profile';
my @recent_maps;
my $RECENT_MAP_LIMIT = 5;
my $MAP_LIST_MESSAGE_DELAY_SECONDS = 0.3;
my $status_snapshot;
my $human_player_snapshot;
my $list_output_active = 0;
my @deferred_chat_messages;
my %client_team_by_slot;
my %client_guid_by_slot;
my %ping_stats_by_player;
my $timelimit_suspended_for_humans = 0;
my $custom_vote;

my %BOT_SKILL_MODES = (
    easy    => [1, 2],
    medium  => [2, 3],
    hard    => [4, 5],
    random  => [1, 5],
    profile => undef,
);
my %CUSTOM_VOTE_COMMANDS = map { $_ => 1 } qw(
    nextmap map setbots botseasy botsmedium botshard botsrandom botsprofile botskill
    startrotation rotation1 rotation2 rotation3 rotation4 rotation5 rotation6
);

sub timestamp {
    my ($when) = @_;
    $when = time unless defined $when;
    return strftime('%Y-%m-%d %H:%M:%S', localtime($when));
}

sub debug { print '[' . timestamp() . "][DEBUG] $_[0]\n" if $opt{debug}; }

sub record_panel_response {
    my ($message) = @_;
    return unless defined $panel_request_id;
    $message //= '';
    $message =~ s/[\t\r\n]+/ /g;
    my $file = $opt{command_file} . '.responses';
    open my $response, '>>:raw', $file or do {
        debug("Cannot write panel response file: $!");
        return;
    };
    print {$response} "$panel_request_id\t$message\n";
    close $response;
}

sub say_list_message {
    my ($message) = @_;
    record_panel_response($message);
    rcon('say ' . quote_q3($message));
}

sub begin_list_output {
    $list_output_active = 1;
}

sub end_list_output {
    $list_output_active = 0;
    return unless @deferred_chat_messages;
    my @messages = @deferred_chat_messages;
    @deferred_chat_messages = ();
    for my $message (@messages) {
        rcon('say ' . quote_q3($message));
        sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);
    }
}

sub show_rotation_maps {
    my ($rotation) = @_;
    my @maps = @{ $ROTATIONS{$rotation} };
    print "\nRotation $rotation (" . scalar(@maps) . "):\n";
    say_list_message("^3=== Maps: $rotation ===");
    sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);
    for (my $index = 0; $index < @maps; ++$index) {
        my $end_of_line = (($index + 1) % 3 == 0 || $index == $#maps);
        printf "  %-20s%s", $maps[$index], ($end_of_line ? "\n" : '');
        next unless $end_of_line;
        my $start = $index - ($index % 3);
        my $line = join ' | ', @maps[$start .. $index];
        # Use say only: it is more reliable than echo in the game console.
        # The delay prevents server chat flood protection from dropping lines.
        say_list_message("^3Maps:^7 $line");
        sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);
    }
}

sub show_maps {
    my ($all) = @_;
    begin_list_output();
    if ($all) {
        print "\nAll map rotations:\n";
        show_rotation_maps($_) for sort keys %ROTATIONS;
        end_list_output();
        return;
    }
    show_rotation_maps($active_rotation);
    end_list_output();
}

sub show_bots {
    begin_list_output();
    print "\nConfigured bots (" . scalar(@BOTS) . "):\n";
    rcon('echo ' . quote_q3('=== Configured bots ==='));
    say_list_message('^3=== Configured bots ===');
    for my $index (0 .. $#BOTS) {
        my $bot = $BOTS[$index];
        # Keep aliases colored, but explicitly reset the real character name
        # to white so alias color codes cannot bleed into it.
        my $line = "$bot->{model}^7 = ^7$bot->{character}^7 | Skill: $bot->{skill}";
        print "  $line\n";
        say_list_message("^3Bot:^7 $line");
        # Avoid server chat flood protection; do not delay after the final bot.
        sleep(0.5) if $index < $#BOTS;
    }
    end_list_output();
}

sub write_bot_skill_file {
    my ($file) = @_;
    open my $fh, '>', $file or do {
        debug("Cannot write bot skill configuration $file: $!");
        return 0;
    };
    print {$fh} "# Smoking Guns bot configuration\n";
    print {$fh} "# Format: bot = character | colored_name | skill | team | delay_ms\n";
    print {$fh} "# Updated by ?botskill <character> <skill>.\n";
    for my $bot (@BOTS) {
        print {$fh} "bot = $bot->{character} | $bot->{model} | $bot->{skill} | $bot->{team} | $bot->{delay_ms}\n";
    }
    close $fh or do {
        debug("Cannot close bot skill configuration $file: $!");
        return 0;
    };
    return 1;
}

sub load_bot_skill_file {
    my $file = $opt{botskill_config_file};
    open my $fh, '<', $file or die "Cannot read bot configuration $file: $!\n";
    @BOTS = ();
    my %characters;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        $line =~ s/#.*\z//;
        next unless $line =~ /\S/;
        unless ($line =~ /^\s*bot\s*=\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([1-5])\s*\|\s*(red|blue)\s*\|\s*(\d+)\s*\z/i) {
            debug("Ignored invalid bot configuration entry in $file: $line");
            next;
        }
        my ($character, $model, $skill, $team, $delay_ms) = ($1, $2, $3, lc($4), $5);
        $character =~ s/^\s+|\s+$//g;
        $model =~ s/^\s+|\s+$//g;
        unless ($character =~ /^[A-Za-z0-9_]+$/ && length $model && $delay_ms <= 60000) {
            debug("Ignored unsafe bot configuration entry in $file: $line");
            next;
        }
        if ($characters{lc $character}++) {
            debug("Ignored duplicate bot character in $file: $character");
            next;
        }
        push @BOTS, {
            character => $character,
            model     => $model,
            skill     => int($skill),
            team      => $team,
            delay_ms  => int($delay_ms),
        };
    }
    close $fh;
    die "No valid bot configurations found in $file\n" unless @BOTS;
    debug('Loaded ' . scalar(@BOTS) . " bot configurations from $file.");
}

sub set_bot_profile_skill {
    my ($character, $skill) = @_;
    my ($bot) = grep { lc($_->{character}) eq lc($character) } @BOTS;
    return say_message("^1Bot skill:^7 unknown bot $character") unless defined $bot;
    return say_message('^1Bot skill:^7 skill must be between 1 and 5.')
        unless defined $skill && $skill =~ /^[1-5]$/;

    $bot->{skill} = int $skill;
    unless (write_bot_skill_file($opt{botskill_config_file})) {
        return say_message('^1Bot skill:^7 could not save the bot skill file.');
    }
    debug("Profile skill for $bot->{character} changed to $bot->{skill}.");
    say_message("^3Bot skill:^7 $bot->{character} profile set to $bot->{skill}.");
    say_message('^3Bot skill:^7 use ?botsprofile to apply profile skills to active bots.');
}

sub say_player_list {
    my ($label, $players, $one_player_per_line, $sort_key) = @_;
    my @guids = sort {
        my $comparison = 0;
        if (defined $sort_key) {
            my $value_a = ref $players->{$a} eq 'HASH' ? ($players->{$a}{$sort_key} // '') : '';
            my $value_b = ref $players->{$b} eq 'HASH' ? ($players->{$b}{$sort_key} // '') : '';
            $comparison = $value_b cmp $value_a;
        }
        my $name_a = ref $players->{$a} eq 'HASH' ? $players->{$a}{text} : $players->{$a};
        my $name_b = ref $players->{$b} eq 'HASH' ? $players->{$b}{text} : $players->{$b};
        $comparison || (lc($name_a) cmp lc($name_b));
    } keys %$players;
    return say_list_message("^3$label:^7 none") unless @guids;
    say_list_message("^3$label (" . scalar(@guids) . '):^7');
    my @line;
    my $length = 0;
    for my $guid (@guids) {
        my $text = ref $players->{$guid} eq 'HASH' ? $players->{$guid}{text} : $players->{$guid};
        my $name = $text . '^7';
        if ($one_player_per_line) {
            say_list_message('^7' . $name);
            sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);
            next;
        }
        my $next_length = $length + length($name) + (@line ? 3 : 0);
        if (@line && $next_length > 100) {
            say_list_message('^7' . join(' | ', @line));
            sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);
            @line = ( $name );
            $length = length $name;
        }
        else {
            push @line, $name;
            $length = $next_length;
        }
    }
    say_list_message('^7' . join(' | ', @line)) if @line;
}

sub read_database_config {
    my ($file) = @_;
    return {} unless -e $file;
    open my $config, '<', $file or do {
        debug("Cannot read database configuration $file: $!");
        return {};
    };
    my %config;
    while (my $line = <$config>) {
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ m{^(?:#|//|;)};
        next unless $line =~ /^(host|port|database|user|password)\s*=\s*(.*?)\s*$/i;
        my ($key, $value) = (lc($1), $2);
        $value =~ s/^"|"$//g;
        $config{$key} = $value;
    }
    close $config;
    return \%config;
}

sub database_handle {
    eval { require DBI; 1 } or do {
        debug('DBI is not installed; ?lastonline cannot query MySQL.');
        say_message('^1Player stats:^7 Perl DBI is not installed.');
        return undef;
    };
    my $config = read_database_config($opt{database_config_file});
    my $password = $config->{password};
    unless (defined $password && length $password) {
        debug("No database password found in $opt{database_config_file}.");
        say_message('^1Player stats:^7 database password is not configured.');
        return undef;
    }
    my $host = $config->{host} // $opt{database_host};
    my $port = $config->{port} // $opt{database_port};
    my $database = $config->{database} // $opt{database_name};
    my $user = $config->{user} // $opt{database_user};
    my $dsn = "DBI:mysql:database=$database;host=$host;port=$port";
    my $dbh = DBI->connect($dsn, $user, $password, {
        RaiseError => 0,
        PrintError => 0,
        AutoCommit => 1,
        mysql_enable_utf8mb4 => 1,
    });
    unless ($dbh) {
        debug('MySQL connection for ?lastonline failed.');
        say_message('^1Player stats:^7 database connection failed.');
        return undef;
    }
    return $dbh;
}

sub local_midnight {
    my ($days_before) = @_;
    my @local = localtime(time - $days_before * 86_400);
    return timelocal(0, 0, 0, $local[3], $local[4], $local[5]);
}

sub database_players_since {
    my ($dbh, $since) = @_;
    my $since_utc = strftime('%Y-%m-%d %H:%M:%S', gmtime($since));
    my $sql = q{
        SELECT utc_datetime_came, utc_datetime_gone,
               duration_hours, duration_minutes, name
          FROM q_playerstat
         WHERE utc_datetime_came >= ?
         ORDER BY utc_datetime_came ASC
    };
    my $statement = $dbh->prepare($sql);
    unless ($statement && $statement->execute($since_utc)) {
        debug('MySQL player statistics query failed.');
        return undef;
    }
    my %players;
    while (my $row = $statement->fetchrow_hashref) {
        next unless defined $row->{name} && length $row->{name};
        my $name = $row->{name};
        $name =~ s/[";\r\n]//g;
        next unless length $name;
        my $key = lc $name;
        my $duration = int($row->{duration_hours} // 0) * 60
            + int($row->{duration_minutes} // 0);
        $players{$key}{name} = $name;
        $players{$key}{minutes} += $duration;
        $players{$key}{came} = $row->{utc_datetime_came};
        if (defined $row->{utc_datetime_gone} && length $row->{utc_datetime_gone}) {
            # The q_playerstat view already returns Berlin local time.
            $players{$key}{gone} = $row->{utc_datetime_gone};
            $players{$key}{gone_sort} = $row->{utc_datetime_gone};
            $players{$key}{gone_timezone} = 'Berlin';
        }
    }
    $statement->finish;
    my %display_players;
    for my $key (keys %players) {
        my $last_visit = $players{$key}{gone} // 'active';
        my $timezone = $players{$key}{gone_timezone} // 'Berlin';
        $last_visit .= " $timezone" unless $last_visit eq 'active';
        $display_players{$key} = {
            text            => "^5$last_visit^7 | ^2$players{$key}{name}^7",
            last_visit_sort => $players{$key}{gone_sort} // $players{$key}{came} // '',
        };
    }
    return \%display_players;
}

sub show_player_stats {
    my $dbh = database_handle();
    return unless defined $dbh;
    my @now = localtime;
    my $today_start = local_midnight(0);
    my $week_start = local_midnight(($now[6] + 6) % 7);
    my $today_players = database_players_since($dbh, $today_start);
    my $week_players = database_players_since($dbh, $week_start);
    $dbh->disconnect;
    return say_message('^3Player stats:^7 database query failed.')
        unless defined $today_players && defined $week_players;

    begin_list_output();
    say_player_list('Players today - last visit', $today_players, 1, 'last_visit_sort');
    sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);
    say_player_list('Players this week - last visit', $week_players, 1, 'last_visit_sort');
    end_list_output();
}

sub local_month_start {
    my @local = localtime;
    return timelocal(0, 0, 0, 1, $local[4], $local[5]);
}

sub format_play_duration {
    my ($minutes) = @_;
    $minutes = int($minutes // 0);
    my $hours = int($minutes / 60);
    my $remaining_minutes = $minutes % 60;
    return $hours ? "${hours}h ${remaining_minutes}m" : "${remaining_minutes}m";
}

sub database_activity_statistics {
    my ($dbh, $since) = @_;
    my $since_local = strftime('%Y-%m-%d %H:%M:%S', localtime($since));
    my $player_sql = q{
        SELECT name, COUNT(*) AS sessions,
               SUM(COALESCE(duration_hours, 0) * 60 + COALESCE(duration_minutes, 0)) AS minutes
          FROM q_playerstat
         WHERE utc_datetime_came >= ?
         GROUP BY name
    };
    my $player_statement = $dbh->prepare($player_sql);
    unless ($player_statement && $player_statement->execute($since_local)) {
        debug('MySQL activity player statistics query failed.');
        return undef;
    }
    my @players;
    while (my $row = $player_statement->fetchrow_hashref) {
        next unless defined $row->{name} && length $row->{name};
        my $name = $row->{name};
        $name =~ s/[";\r\n]//g;
        next unless length $name;
        push @players, { name => $name, sessions => int($row->{sessions} // 0), minutes => int($row->{minutes} // 0) };
    }
    $player_statement->finish;

    my $weekday_sql = q{
        SELECT DAYOFWEEK(utc_datetime_came) AS weekday, COUNT(*) AS sessions,
               SUM(COALESCE(duration_hours, 0) * 60 + COALESCE(duration_minutes, 0)) AS minutes
          FROM q_playerstat
         WHERE utc_datetime_came >= ?
         GROUP BY DAYOFWEEK(utc_datetime_came)
    };
    my $weekday_statement = $dbh->prepare($weekday_sql);
    unless ($weekday_statement && $weekday_statement->execute($since_local)) {
        debug('MySQL activity weekday statistics query failed.');
        return undef;
    }
    my @weekdays;
    while (my $row = $weekday_statement->fetchrow_hashref) {
        push @weekdays, { weekday => int($row->{weekday} // 0), sessions => int($row->{sessions} // 0), minutes => int($row->{minutes} // 0) };
    }
    $weekday_statement->finish;
    return { players => \@players, weekdays => \@weekdays };
}

sub say_activity_leaders {
    my ($label, $players, $sort_field) = @_;
    my @leaders = sort {
        $b->{$sort_field} <=> $a->{$sort_field}
            || $b->{minutes} <=> $a->{minutes}
            || $b->{sessions} <=> $a->{sessions}
            || lc($a->{name}) cmp lc($b->{name})
    } @$players;
    return say_list_message("^3$label:^7 none") unless @leaders;
    say_list_message("^3$label:^7");
    my $last_index = $#leaders < 2 ? $#leaders : 2;
    for my $index (0 .. $last_index) {
        my $player = $leaders[$index];
        my $rank = $index + 1;
        say_list_message("^3#$rank^7 $player->{name}^7 - $player->{sessions} sessions - " . format_play_duration($player->{minutes}));
        sleep($MAP_LIST_MESSAGE_DELAY_SECONDS) if $index < $last_index;
    }
}

sub show_statistic {
    my $dbh = database_handle();
    return unless defined $dbh;
    my @now = localtime;
    my $week_start = local_midnight(($now[6] + 6) % 7);
    my $week = database_activity_statistics($dbh, $week_start);
    my $month = database_activity_statistics($dbh, local_month_start());
    $dbh->disconnect;
    return say_message('^3Statistics:^7 database query failed.') unless defined $week && defined $month;

    begin_list_output();
    say_list_message('^2=== Player Activity Statistics ===');
    say_activity_leaders('This week - most sessions', $week->{players}, 'sessions');
    sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);
    say_activity_leaders('This week - longest playtime', $week->{players}, 'minutes');
    sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);
    say_activity_leaders('This month - most sessions', $month->{players}, 'sessions');
    sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);
    say_activity_leaders('This month - longest playtime', $month->{players}, 'minutes');
    sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);

    my @weekday_names = qw(Sunday Monday Tuesday Wednesday Thursday Friday Saturday);
    my @weekdays = sort {
        $b->{sessions} <=> $a->{sessions} || $b->{minutes} <=> $a->{minutes} || $a->{weekday} <=> $b->{weekday}
    } @{ $month->{weekdays} };
    if (@weekdays) {
        say_list_message('^3Most played weekdays this month:^7');
        for my $index (0 .. $#weekdays) {
            my $day = $weekdays[$index];
            my $name = $weekday_names[$day->{weekday} - 1] // 'Unknown';
            say_list_message("^3$name:^7 $day->{sessions} sessions - " . format_play_duration($day->{minutes}));
            sleep($MAP_LIST_MESSAGE_DELAY_SECONDS) if $index < $#weekdays;
        }
    }
    else {
        say_list_message('^3Most played weekdays this month:^7 none');
    }
    end_list_output();
}

sub show_controller_version {
    say_message("^3Controller version:^7 $CONTROLLER_VERSION");
}
sub show_xlrstats {
    my ($line) = @_;
    my $guid = chat_client_guid($line);
    return say_message('^3XLRstats:^7 your GUID is not available yet.') unless defined $guid;

    my $dbh = database_handle();
    return unless defined $dbh;
    my $sql = q{
        SELECT clients.name, xlr_playerstats.skill, xlr_playerstats.kills,
               xlr_playerstats.deaths, xlr_playerstats.ratio,
               xlr_playerstats.assists, xlr_playerstats.winstreak, xlr_playerstats.losestreak, xlr_playerstats.rounds
          FROM clients
          INNER JOIN xlr_playerstats ON xlr_playerstats.client_id = clients.id
         WHERE clients.guid = ?
         LIMIT 1
    };
    my $statement = $dbh->prepare($sql);
    unless ($statement && $statement->execute($guid)) {
        $dbh->disconnect;
        debug('MySQL XLRstats query failed.');
        return say_message('^3XLRstats:^7 database query failed.');
    }
    my $row = $statement->fetchrow_hashref;
    $statement->finish;
    $dbh->disconnect;
    return say_message('^3XLRstats:^7 no statistics found.') unless defined $row;

    my $name = $row->{name} // 'Player';
    $name =~ s/[";\r\n]//g;
    my $skill = sprintf('%.2f', $row->{skill} // 0);
    my $ratio = sprintf('%.2f', $row->{ratio} // 0);
    my $kills = int($row->{kills} // 0);
    my $deaths = int($row->{deaths} // 0);
    my $assists = int($row->{assists} // 0);
    my $winstreak = int($row->{winstreak} // 0);
    my $losestreak = int($row->{losestreak} // 0);
    my $rounds = int($row->{rounds} // 0);
    say_message("^3$name ^1| ^7S $skill ^1| ^AK $kills D $deaths ^1| ^5R $ratio ^1| ^2WS $winstreak ^1| ^1LS $losestreak ^1| ^DRO $rounds");
}

sub show_top10 {
    my $dbh = database_handle();
    return unless defined $dbh;
    my $sql = q{
        SELECT clients.name, xlr_playerstats.skill, xlr_playerstats.kills,
               xlr_playerstats.deaths, xlr_playerstats.ratio,
               xlr_playerstats.assists, xlr_playerstats.winstreak, xlr_playerstats.losestreak, xlr_playerstats.rounds
          FROM clients
          INNER JOIN xlr_playerstats ON xlr_playerstats.client_id = clients.id
         ORDER BY xlr_playerstats.skill DESC
         LIMIT 10
    };
    my $statement = $dbh->prepare($sql);
    unless ($statement && $statement->execute) {
        $dbh->disconnect;
        debug('MySQL XLRstats top 10 query failed.');
        return say_message('^3Top 10:^7 database query failed.');
    }
    my @players;
    while (my $row = $statement->fetchrow_hashref) {
        my $name = $row->{name} // 'Player';
        $name =~ s/[";\r\n]//g;
        push @players, {
            name   => $name,
            skill  => sprintf('%.2f', $row->{skill} // 0),
            kills  => int($row->{kills} // 0),
            deaths => int($row->{deaths} // 0),
            ratio  => sprintf('%.2f', $row->{ratio} // 0),
        };
    }
    $statement->finish;
    $dbh->disconnect;
    return say_message('^3Top 10:^7 no statistics found.') unless @players;

    begin_list_output();
    say_list_message('^3=== XLRstats Top 10 (Skill) ===');
    for my $index (0 .. $#players) {
        my $player = $players[$index];
        my $rank = $index + 1;
        say_list_message("^3#$rank^7 $player->{name}^7 | skill $player->{skill} | K $player->{kills} D $player->{deaths} | ratio $player->{ratio}");
        sleep($MAP_LIST_MESSAGE_DELAY_SECONDS) if $index < $#players;
    }
    end_list_output();
}

sub say_message {
    my ($message) = @_;
    record_panel_response($message);
    if ($list_output_active) {
        push @deferred_chat_messages, $message;
        return;
    }
    rcon('say ' . quote_q3($message));
}

sub announce_controller {
    my $message = "TFC map and bot controller via RCON v$CONTROLLER_VERSION";
    print "$message\n";
    say_message("^3$message^7");
}

sub remember_map {
    my ($map) = @_;
    return if @recent_maps && $recent_maps[-1] eq $map;
    push @recent_maps, $map;
    shift @recent_maps while @recent_maps > $RECENT_MAP_LIMIT;
}

sub show_status {
    my $bots = active_bot_slots();
    my $count = defined $bots ? scalar @$bots : 'unknown';
    my $setting = settings_for_map($last_map);
    my $humans = active_humans();
    my $timelimit = $setting->{timelimit_minutes} . ' min';
    $timelimit .= ' (paused)' if defined $humans && $humans > 0;
    my $next_map = defined $scheduled_next_map ? $scheduled_next_map : 'unknown';
    say_message("^3Status:^7 map $last_map | next $next_map | $active_rotation | skill $bot_skill_mode | fraglimit $setting->{fraglimit} | timelimit $timelimit | bots $count/$opt{max_bots}");
}

sub show_rotation_status {
    my $count = scalar @{ $ROTATIONS{$active_rotation} };
    say_message("^3Rotation:^7 $active_rotation ($count maps), recent: " . (@recent_maps ? join(', ', @recent_maps) : 'none'));
}

sub show_bot_status {
    my $bots = active_bot_slots();
    return say_message('^3Bot status:^7 unavailable') unless defined $bots;
    my $slots = @$bots ? join(', ', @$bots) : 'none';
    say_message("^3Bot status:^7 " . scalar(@$bots) . " active - slots: $slots - skill mode: $bot_skill_mode");
}

sub active_human_ping_clients {
    my $status = server_status();
    return undef unless $status =~ /^map:\s*/mi;

    my $is_64bit_status = $status =~ /^cl\s+score\s+ping\s+name\s+address\s+rate\s*$/mi;
    my @clients;
    for my $line (split /\n/, $status) {
        next unless $line =~ /^\s*(\d+)\s+/;
        my $slot = $1;
        my $plain_line = strip_q3_colors($line);
        next if $plain_line =~ /\sbot\s/i;
        next if $line =~ /\sSPECTATOR\s/i;
        next if defined $client_team_by_slot{$slot} && $client_team_by_slot{$slot} == 3;

        my ($ping, $name);
        if ($is_64bit_status) {
            ($ping, $name) = $line =~ /^\s*\d+\s+-?\d+\s+(-?\d+)\s+(.+?)\s+(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\s+\d+\s*$/;
        }
        else {
            ($ping, $name) = $line =~ /^\s*\d+\s+-?\d+\s+(-?\d+)\s+(.+?)\s+\d+\s+(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\s+\d+\s+\d+\s*$/;
        }
        next unless defined $ping && defined $name && $ping >= 0;
        $name =~ s/^\s+|\s+$//g;
        next unless length $name;
        push @clients, { slot => $slot, ping => int($ping), name => $name };
    }
    return \@clients;
}

sub record_ping_samples {
    my $clients = active_human_ping_clients();
    return undef unless defined $clients;
    my $now = time;
    my @keys;
    for my $client (@$clients) {
        my $slot = $client->{slot};
        my $plain_name = strip_q3_colors($client->{name});
        my $key = defined $client_guid_by_slot{$slot}
            ? 'guid:' . lc($client_guid_by_slot{$slot})
            : "slot:$slot";
        my $stats = $ping_stats_by_player{$key};
        if (defined $stats && ($stats->{plain_name} // '') ne $plain_name) {
            # A slot without a GUID was reused by a different player.
            undef $stats;
            delete $ping_stats_by_player{$key};
        }
        $stats //= {
            count      => 0,
            sum        => 0,
            min        => undef,
            min_at     => undef,
            max        => undef,
            max_at     => undef,
        };
        my $ping = $client->{ping};
        ++$stats->{count};
        $stats->{sum} += $ping;
        if (!defined $stats->{min} || $ping < $stats->{min}) {
            $stats->{min} = $ping;
            $stats->{min_at} = $now;
        }
        if (!defined $stats->{max} || $ping > $stats->{max}) {
            $stats->{max} = $ping;
            $stats->{max_at} = $now;
        }
        $stats->{name} = $client->{name};
        $stats->{plain_name} = $plain_name;
        $stats->{average_at} = $now;
        $ping_stats_by_player{$key} = $stats;
        push @keys, $key;
    }
    return \@keys;
}

sub show_ping_stats {
    my $keys = record_ping_samples();
    return say_message('^3Ping:^7 server status is unavailable.') unless defined $keys;
    return say_message('^3Ping:^7 no active human player ping samples.') unless @$keys;

    begin_list_output();
    say_list_message('^2=== Active Player Ping Statistics ===');
    sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);
    for my $key (sort { lc($ping_stats_by_player{$a}{plain_name}) cmp lc($ping_stats_by_player{$b}{plain_name}) } @$keys) {
        my $stats = $ping_stats_by_player{$key};
        my $name = $stats->{name} // 'Player';
        $name =~ s/[";\r\n]//g;
        my $average = int($stats->{sum} / $stats->{count} + 0.5);
        say_list_message("^3Ping:^7 $name^7");
        say_list_message('^1High:^7 ' . $stats->{max} . ' ms @ ' . timestamp($stats->{max_at})
            . ' ^3Average:^7 ' . $average . ' ms @ ' . timestamp($stats->{average_at})
            . ' ^2Low:^7 ' . $stats->{min} . ' ms @ ' . timestamp($stats->{min_at}));
        sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);
    }
    end_list_output();
}
sub say_info_entry {
    my ($command, $text) = @_;
    # Keep game chat below the engine message limit. Continuation lines contain
    # only the white description, while command names are cyan.
    my $line = "^3$command ^7";
    for my $word (split /\s+/, $text) {
        my $candidate = length($line) > 3 ? "$line $word" : "^7$word";
        if (length(strip_q3_colors($candidate)) > 112 && length($line) > 3) {
            say_list_message($line);
            sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);
            $line = "^7$word";
        }
        else {
            $line = $candidate;
        }
    }
    say_list_message($line) if length($line) > 3;
}

sub show_info {
    my @entries = (
        ['?help', 'Prints the available commands.'],
        ['?info', 'Prints a color-coded reference for every controller command and its result.'],
        ['?version', 'Shows the controller version.'],
        ['?status', 'Prints current map, active rotation, skill mode, and bot count.'],
        ['?rotationstatus', 'Prints the active rotation and recently used maps.'],
        ['?botstatus', 'Prints the active bot count, bot slots, and skill mode.'],
        ['?ping', 'Shows highest, average, and lowest ping with timestamps for active human players.'],
        ['?showmaps / ?showmaps all', 'Shows maps from the active rotation or all rotations.'],
        ['?showbots', 'Shows all configured aliases, character names, and profile skills.'],
        ['?lastonline', 'Lists players seen today and since Monday, with their latest visit from q_playerstat.'],
        ['?statistic', 'Shows weekly and monthly player activity plus most played weekdays.'],
        ['?xlrstats', 'Shows the requesting player XLRstats skill, kills, deaths, ratio, win streak, loss streak, rounds, and name.'],
        ['?top10', 'Shows the ten highest-skill XLRstats players, one per chat line.'],
        ['?yes / ?no', 'Casts a vote for or against the currently active custom controller vote.'],
        ['?rotation1 ... ?rotation6', 'Selects the rotation for the next random map.'],
        ['?startrotation <1-6>', 'Selects the requested rotation and immediately starts a random map from that rotation only. ?startrotation rotation3 is also accepted.'],
        ['?nextmap', 'With 0-1 human players, immediately starts a random map from the active rotation. With 2+ human players, starts a custom chat vote.'],
        ['?map MAPNAME', 'Immediately starts a specific known map from any rotation.'],
        ['?setbots 0-8', 'Changes min_botplayer and immediately adds or removes bots to reach the reduced target, subject to free client slots. It never adds a duplicate of an active configured bot.'],
        ['?botseasy, ?botsmedium, ?botshard, ?botsrandom', 'Changes bot skill mode and recreates the bots immediately.'],
        ['?botsprofile', 'Applies the individual skill values from botskills.cfg and recreates the bots.'],
        ['?botskill CHARACTER 1-5', 'Saves one individual profile skill in botskills.cfg, use ?botsprofile to apply it to active bots.'],
    );

    begin_list_output();
    say_list_message('^2=== TFC Map and Bot Controller: Command Info ===');
    sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);
    for my $entry (@entries) {
        say_info_entry(@$entry);
        sleep($MAP_LIST_MESSAGE_DELAY_SECONDS);
    }
    end_list_output();
}
sub show_help {
    say_message('^3Commands:^7 ?help ?info ?version ?status ?rotationstatus ?showmaps [all] ?showbots ?botstatus');
    say_message('^3Player commands:^7 ?lastonline ?statistic ?xlrstats ?top10 ?ping');
    say_message('^3Map commands:^7 ?rotation1 ?rotation2 ?rotation3 ?rotation4 ?rotation5 ?rotation6');
    say_message('^3Map commands:^7 ?nextmap ?map <mapname> ?startrotation <1-6>');
    say_message('^3Bot commands:^7 ?setbots <0-8> ?botseasy ?botsmedium ?botshard ?botsrandom ?botsprofile');
    say_message('^3Bot commands:^7 ?botskill <character> <1-5>');
    say_message('^3Custom vote:^7 ?yes ?no (used for controller changes with 2+ players)');
}

sub set_min_bots {
    my ($value) = @_;
    $value = 0 if $value < 0;
    $value = $opt{max_bots} if $value > $opt{max_bots};
    $opt{min_botplayer} = $value;
    debug("Minimum managed bots changed to $value.");
    my $setting = settings_for_map($last_map);
    my $humans = active_humans();
    return say_message('^1Bot minimum:^7 player count unavailable.') unless defined $humans;
    my $desired = desired_bot_count($setting, $humans);
    my $actual = set_active_bot_count($desired);
    if (defined $actual) {
        say_message("^3Bot minimum:^7 $value - ^3target now:^7 $desired - ^3active now:^7 $actual");
    }
    else {
        say_message("^3Bot minimum:^7 $value - ^1bot update failed.^7");
    }
}

sub start_selected_map {
    my ($map, $reason, $requested_rotation) = @_;
    # Keep an explicitly selected rotation when a map name exists in more than
    # one rotation. This is essential for ?nextmap and for DM/BR map variants.
    my $rotation;
    if (defined $requested_rotation) {
        return unless map_is_in_rotation($map, $requested_rotation);
        $rotation = $requested_rotation;
    }
    else {
        $rotation = rotation_for_map($map, $active_rotation);
    }
    return unless defined $rotation;
    finish_current_map($last_map, $reason) if defined $last_map;
    $active_rotation = $rotation;
    $last_map = $map;
    $next_change_at = start_round($last_map);
}

sub command_allowed {
    my ($line) = @_;
    my ($command) = $line =~ /\?([A-Za-z][A-Za-z0-9_]*)\b/;
    return 0 unless defined $command;
    $command = lc $command;

    my $allowed_guids = $opt{command_admin_guids}{$command};
    unless (defined $allowed_guids && ref $allowed_guids eq 'ARRAY') {
        debug("Ignored unknown command ?$command.");
        return 0;
    }
    return 1 unless @$allowed_guids;

    my ($slot) = $line =~ /\b(?:say|sayteam):\s*(\d+)\s*:/i;
    my $guid = defined $slot ? $client_guid_by_slot{$slot} : undef;
    unless (defined $guid) {
        debug("Ignored ?$command because the player GUID is unavailable.");
        return 0;
    }

    for my $admin_guid (@$allowed_guids) {
        return 1 if uc($guid) eq uc($admin_guid);
    }
    debug("Ignored ?$command from unauthorized GUID $guid.");
    return 0;
}

sub chat_client_guid {
    my ($line) = @_;
    my ($slot) = $line =~ /\b(?:say|sayteam):\s*(\d+)\s*:/i;
    return unless defined $slot;
    return if defined $client_team_by_slot{$slot} && $client_team_by_slot{$slot} == 3;
    return $client_guid_by_slot{$slot};
}

sub custom_vote_description {
    my ($command, $arguments) = @_;
    my $safe_arguments = $arguments // '';
    $safe_arguments =~ s/[^A-Za-z0-9_ -]//g;
    $safe_arguments =~ s/^\s+|\s+$//g;
    return '?' . $command . (length $safe_arguments ? " $safe_arguments" : '');
}

sub expire_custom_vote {
    return unless defined $custom_vote;
    return unless time >= $custom_vote->{expires_at};
    say_message('^1Custom vote failed:^7 time expired.');
    debug('Custom vote expired: ' . $custom_vote->{description});
    undef $custom_vote;
}

sub start_custom_vote {
    my ($command, $arguments, $line, $human_count) = @_;
    expire_custom_vote();
    if (defined $custom_vote) {
        say_message('^1Custom vote:^7 another vote is already active.');
        return 1;
    }

    my $proposer_guid = chat_client_guid($line);
    unless (defined $proposer_guid) {
        say_message('^1Custom vote:^7 your GUID is not available yet. Please try again.');
        debug("Cannot start custom vote for ?$command because the proposer GUID is unavailable.");
        return 1;
    }

    my $required_yes = int($human_count / 2) + 1;
    my $description = custom_vote_description($command, $arguments);
    $custom_vote = {
        command      => $command,
        arguments    => $arguments,
        description  => $description,
        voter_count  => $human_count,
        required_yes => $required_yes,
        expires_at   => time + $opt{custom_vote_seconds},
        yes          => { $proposer_guid => 1 },
        no           => {},
    };
    debug("Custom vote started: $description by GUID $proposer_guid.");
    say_message("^3Custom vote:^7 $description - type ^2?yes^7 or ^1?no^7 ($opt{custom_vote_seconds}s, $required_yes yes required).");
    return 1;
}

sub cast_custom_vote {
    my ($line, $choice) = @_;
    expire_custom_vote();
    return say_message('^3Custom vote:^7 no vote is active.') unless defined $custom_vote;

    my $guid = chat_client_guid($line);
    return say_message('^1Custom vote:^7 your GUID is not available yet.') unless defined $guid;

    my $opposite_choice = $choice eq 'yes' ? 'no' : 'yes';
    delete $custom_vote->{$opposite_choice}{$guid};
    $custom_vote->{$choice}{$guid} = 1;
    my $yes = scalar keys %{ $custom_vote->{yes} };
    my $no = scalar keys %{ $custom_vote->{no} };
    my $required_yes = $custom_vote->{required_yes};
    my $description = $custom_vote->{description};

    if ($yes >= $required_yes) {
        my ($command, $arguments) = @{$custom_vote}{qw(command arguments)};
        undef $custom_vote;
        say_message("^2Custom vote passed:^7 $description");
        debug("Custom vote passed: $description ($yes yes, $no no).");
        execute_controller_command($command, $arguments);
        return;
    }

    if (($custom_vote->{voter_count} - $no) < $required_yes) {
        say_message("^1Custom vote failed:^7 $description");
        debug("Custom vote failed: $description ($yes yes, $no no).");
        undef $custom_vote;
        return;
    }

    say_message("^3Custom vote:^7 $description - $yes/$required_yes yes, $no no.");
}

sub execute_controller_command {
    my ($command, $arguments, $line) = @_;
    if ($command eq 'help') {
        show_help();
    }
    elsif ($command eq 'info') {
        show_info();
    }
    elsif ($command eq 'version') {
        show_controller_version();
    }
    elsif ($command eq 'status') {
        show_status();
    }
    elsif ($command eq 'rotationstatus') {
        show_rotation_status();
    }
    elsif ($command eq 'botstatus') {
        show_bot_status();
    }
    elsif ($command eq 'ping') {
        show_ping_stats();
    }
    elsif ($command eq 'setbots' && $arguments =~ /^\s*(-?\d+)\b/) {
        set_min_bots($1);
    }
    elsif ($command eq 'nextmap') {
        my $selected_map = choose_map($last_map, $active_rotation);
        debug("?nextmap selected $selected_map from $active_rotation only.");
        start_selected_map($selected_map, 'manual ?nextmap command', $active_rotation);
    }
    elsif ($command eq 'map' && $arguments =~ /^\s*([A-Za-z0-9_]+)\b/) {
        my $requested_map = $1;
        if (rotation_for_map($requested_map)) {
            start_selected_map($requested_map, 'manual ?map command');
        }
        else {
            say_message("^1Unknown map:^7 $requested_map");
        }
    }
    elsif ($command eq 'botseasy') {
        select_bot_skill_mode('easy');
    }
    elsif ($command eq 'botsmedium') {
        select_bot_skill_mode('medium');
    }
    elsif ($command eq 'botshard') {
        select_bot_skill_mode('hard');
    }
    elsif ($command eq 'botsrandom') {
        select_bot_skill_mode('random');
    }
    elsif ($command eq 'botsprofile') {
        select_bot_skill_mode('profile');
    }
    elsif ($command eq 'botskill' && $arguments =~ /^\s*([A-Za-z0-9_]+)\s+([1-5])\b/) {
        set_bot_profile_skill($1, $2);
    }
    elsif ($command eq 'botskill') {
        say_message('^3Usage:^7 ?botskill <character> <1-5>');
    }
    elsif ($command eq 'startrotation' && $arguments =~ /^\s*(?:rotation)?([1-6])\b/i) {
        start_rotation("rotation$1");
    }
    elsif ($command =~ /^rotation([1-6])$/) {
        select_rotation("rotation$1");
    }
    elsif ($command eq 'showmaps') {
        $arguments =~ /^\s+all\b/i ? show_maps(1) : show_maps(0);
    }
    elsif ($command eq 'showbots') {
        show_bots();
    }
    elsif ($command eq 'lastonline') {
        show_player_stats();
    }
    elsif ($command eq 'statistic') {
        show_statistic();
    }
    elsif ($command eq 'xlrstats') {
        show_xlrstats($line);
    }
    elsif ($command eq 'top10') {
        show_top10();
    }
}

sub process_controller_command {
    my ($line) = @_;
    my ($command, $arguments) = $line =~ /\?([A-Za-z][A-Za-z0-9_]*)\b([^\r\n]*)/;
    return unless defined $command;
    $command = lc $command;
    $arguments //= '';

    if ($command eq 'yes' || $command eq 'no') {
        cast_custom_vote($line, $command);
        return;
    }

    if ($CUSTOM_VOTE_COMMANDS{$command}) {
        my $humans = active_humans();
        if (defined $humans && $humans >= $opt{custom_vote_min_humans}) {
            start_custom_vote($command, $arguments, $line, $humans);
            return;
        }
    }
    execute_controller_command($command, $arguments, $line);
}

sub select_rotation {
    my ($rotation) = @_;
    return unless exists $ROTATIONS{$rotation};
    return if $active_rotation eq $rotation;
    $active_rotation = $rotation;
    my $count = scalar @{ $ROTATIONS{$active_rotation} };
    debug("Map rotation changed to $active_rotation with $count maps; active from the next map.");
    rcon('echo ' . quote_q3("Map rotation $active_rotation selected ($count maps)."));
    rcon('say ' . quote_q3("^3Map rotation:^7 $active_rotation ($count maps) - active from the next map."));
}

sub start_rotation {
    my ($rotation) = @_;
    return unless exists $ROTATIONS{$rotation};
    select_rotation($rotation);
    my $selected_map = choose_map($last_map, $rotation);
    debug("?startrotation selected $selected_map from $rotation only.");
    start_selected_map($selected_map, 'manual ?startrotation command', $rotation);
}

sub skill_for_bot {
    my ($bot) = @_;
    return $bot->{skill} if $bot_skill_mode eq 'profile';
    my ($minimum, $maximum) = @{ $BOT_SKILL_MODES{$bot_skill_mode} };
    return $minimum + int rand($maximum - $minimum + 1);
}

sub select_bot_skill_mode {
    my ($mode) = @_;
    return unless exists $BOT_SKILL_MODES{$mode};
    # Profile mode is deliberately reapplied on every ?botsprofile command so
    # a changed individual value can be applied without a map restart.
    return if $bot_skill_mode eq $mode && $mode ne 'profile';
    $bot_skill_mode = $mode;
    debug("Bot skill mode changed to $mode.");
    rcon('echo ' . quote_q3("Bot skill mode: $mode"));
    rcon('say ' . quote_q3("^3Bot skill mode:^7 $mode"));

    # Recreate active bots without a map change so the setting applies
    # immediately. Human players stay connected.
    return unless defined $last_map;
    my $setting = settings_for_map($last_map);
    my @selected_bots = choose_bots($setting->{min_botplayer});
    print "Applying bot skill mode '$mode' to newly selected bots now.\n";
    install_bots($setting, 0, @selected_bots);
}

sub rotation_for_map {
    my ($map, $preferred_rotation) = @_;
    if (defined $preferred_rotation && exists $ROTATIONS{$preferred_rotation}) {
        return $preferred_rotation
            if grep { $_ eq $map } @{ $ROTATIONS{$preferred_rotation} };
    }
    # A deterministic fallback is used only when no preferred rotation contains
    # the map, for example after a script restart.
    for my $rotation (sort keys %ROTATIONS) {
        return $rotation if grep { $_ eq $map } @{ $ROTATIONS{$rotation} };
    }
    return undef;
}

sub map_is_in_rotation {
    my ($map, $rotation) = @_;
    return 0 unless defined $rotation && exists $ROTATIONS{$rotation};
    return scalar grep { $_ eq $map } @{ $ROTATIONS{$rotation} };
}

sub csv_value {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/"/""/g;
    return qq{"$value"};
}

sub log_map_history {
    my ($event, $when, $map, $duration_seconds, $reason) = @_;
    my $new_file = !-e $opt{map_history_file} || !-s $opt{map_history_file};
    open my $log, '>>:encoding(UTF-8)', $opt{map_history_file}
        or die "Cannot open map history $opt{map_history_file}: $!\n";
    print {$log} "event,timestamp,map,duration_seconds,reason\n" if $new_file;
    print {$log} join(',',
        csv_value($event),
        csv_value(timestamp($when)),
        csv_value($map),
        csv_value($duration_seconds),
        csv_value($reason),
    ) . "\n";
    close $log or warn "Map history could not be fully written: $!\n";
}

sub rcon {
    my ($command) = @_;
    die "Invalid RCON command\n" if $command =~ /[\r\n]/;
    # Console output does not change the server state. Every other command may
    # make a previously cached status response stale.
    unless ($command =~ /^(?:status|dumpuser|say|echo)\b/i) {
        undef $status_snapshot;
        undef $human_player_snapshot;
    }
    debug("RCON -> $command");
    my $socket = IO::Socket::INET->new(
        Proto    => 'udp',
        PeerAddr => $opt{host},
        PeerPort => $opt{port},
    ) or die "Cannot connect to $opt{host}:$opt{port} via UDP: $!\n";
    $socket->autoflush(1);
    $socket->send(pack('l<', -1) . "rcon $opt{password} $command\n");
    my $response = '';
    my $select = IO::Select->new($socket);
    # Wait two seconds for the first response, then briefly for additional
    # UDP packets. This also works on Windows.
    my $wait = 2;
    while ($select->can_read($wait)) {
        my $packet = '';
        last unless $socket->recv($packet, 8192);
        $packet =~ s/^\xFF\xFF\xFF\xFFprint\n//;
        $response .= $packet;
        $wait = 0.1;
    }
    $socket->close;
    $response =~ s/[\r\n]+\z//;
    debug("RCON <- $response") if length $response;
    return $response;
}

sub clear_status_snapshot {
    undef $status_snapshot;
    undef $human_player_snapshot;
}

sub server_status {
    return $status_snapshot if defined $status_snapshot;
    $status_snapshot = rcon('status');
    return $status_snapshot;
}

sub quote_q3 {
    my ($value) = @_;
    die "Invalid console command value\n" if $value =~ /[";\r\n]/;
    return qq{"$value"};
}

sub is_bot_status_line {
    my ($line) = @_;
    # The 32-bit server writes "bot", while the 64-bit server writes
    # "^7bot" in the address column. Remove Quake color codes first.
    my $plain_line = strip_q3_colors($line);
    return $plain_line =~ /\sbot\s/i;
}
sub active_humans {
    # status has a slot number before each client line. Quake 3 denotes bot
    # addresses as 'bot'. The game log provides the current team value.
    return $human_player_snapshot if defined $human_player_snapshot;
    my $status = server_status();
    unless ($status =~ /^map:\s*/mi) {
        debug('Could not read human players from status.');
        return undef;
    }
    my $humans = 0;
    for my $line (split /\n/, $status) {
        next unless $line =~ /^\s*(\d+)\s+/;
        my $slot = $1;
        next if is_bot_status_line($line);
        next if $line =~ /\sSPECTATOR\s/i;
        if (defined $client_team_by_slot{$slot} && $client_team_by_slot{$slot} == 3) {
            debug("Excluded spectator in client slot $slot.");
            next;
        }
        ++$humans;
    }
    debug("Detected human players: $humans");
    $human_player_snapshot = $humans;
    return $human_player_snapshot;
}

sub update_client_team_from_log_line {
    my ($line) = @_;
    if ($line =~ /ClientUserinfoChanged:\s*(\d+)\b/i) {
        my $slot = $1;

        if ($line =~ /\\t\\(\d+)\b/i) {
            $client_team_by_slot{$slot} = $1;
            undef $human_player_snapshot;
        }

        if ($line =~ /\bguid\\([^\\\s]+)/i) {
            $client_guid_by_slot{$slot} = $1;
        }
    }
    elsif ($line =~ /ClientDisconnect:\s*(\d+)\b/i) {
        delete $client_team_by_slot{$1};
        delete $client_guid_by_slot{$1};
        undef $human_player_snapshot;
    }
}

sub load_client_teams_from_game_log {
    my $file = $opt{game_log_file};
    return unless -e $file;
    open my $log, '<:raw', $file or do {
        debug("Cannot open server log for team scan: $!");
        return;
    };
    # The latest team assignment for each connected client is sufficient.
    # Limit the startup scan so an unusually large log cannot delay the server.
    my $size = -s $file;
    my $scan_bytes = 4 * 1024 * 1024;
    if ($size > $scan_bytes) {
        seek $log, $size - $scan_bytes, 0;
        <$log>; # Discard the first partial line after seeking.
    }
    while (my $line = <$log>) {
        update_client_team_from_log_line($line);
    }
    close $log;
    debug('Loaded client team states from the game log.');
}

sub settings_for_map {
    my ($map) = @_;
    my %setting = %opt;
    if (exists $MAP_OVERRIDE{$map}) {
        @setting{keys %{ $MAP_OVERRIDE{$map} }} = values %{ $MAP_OVERRIDE{$map} };
    }
    $setting{min_botplayer} = 0 if $setting{min_botplayer} < 0;
    $setting{min_botplayer} = $setting{max_bots}
        if $setting{min_botplayer} > $setting{max_bots};
    return \%setting;
}

sub desired_bot_count {
    my ($setting, $humans) = @_;
    my $wanted = $setting->{min_botplayer};
    my $threshold = $setting->{human_bot_reduction_threshold};
    if ($humans > $threshold) {
        $wanted -= $humans - $threshold;
    }
    $wanted = 0 if $wanted < 0;
    $wanted = $setting->{max_bots} if $wanted > $setting->{max_bots};
    $wanted = scalar @BOTS if $wanted > @BOTS;
    return $wanted;
}

sub configure_map {
    my ($setting) = @_;
    rcon("seta sv_maxclients $setting->{max_players}");
    rcon("seta fraglimit $setting->{fraglimit}");
    rcon("seta timelimit $setting->{timelimit_minutes}");
    $timelimit_suspended_for_humans = 0;
    disable_automatic_bots();
}

sub apply_human_timelimit_policy {
    my ($setting, $humans) = @_;
    if ($humans > 0) {
        return 0 if $timelimit_suspended_for_humans;
        rcon('seta timelimit 0');
        $timelimit_suspended_for_humans = 1;
        debug("Timelimit disabled while $humans human player(s) are connected.");
        return 0;
    }

    return 0 unless $timelimit_suspended_for_humans;
    rcon("seta timelimit $setting->{timelimit_minutes}");
    $timelimit_suspended_for_humans = 0;
    debug("Timelimit restored for bot-only play: $setting->{timelimit_minutes} minute(s).");
    return 1;
}

sub disable_automatic_bots {
    # Persist the setting as well as applying it now. This prevents the engine
    # from adding unnamed fallback bots such as SGPlayer@0 after a map reset.
    rcon('seta bot_minplayers 0');
}

sub prepare_map {
    my ($map) = @_;
    my $game_type = $ROTATION_GAME_TYPES{$active_rotation};
    die "Unknown rotation game type: $active_rotation\n" unless defined $game_type;
    if ($game_type == 5) {
        rcon('vstr reset');
        rcon('set g_gametype 5');
        rcon("vstr motd_$map");
        return;
    }
    if ($game_type == 1) {
        rcon('vstr reset');
        rcon('set g_gametype 1');
        return;
    }
    # Deathmatch setup. Rotation 2 retains its supplied special map settings.
    rcon('vstr reset');
    rcon('set g_gametype 0');
    if ($active_rotation eq 'rotation2') {
        rcon('vstr motd_dm_warehouse_mini') if $map eq 'dm_warehouse_mini';
        if ($map eq 'dm_knivefun') {
            rcon('vstr expl_knives');
            rcon('set g_startingWeapon 1');
            rcon('set g_removedItems 32767');
        }
    }
    rcon('vstr startSawedOff') if $active_rotation eq 'rotation1' && $map eq 'dm_steamboat';
}

sub remove_all_bots {
    # Do not use `kick allbots`: on dm_ghosttown this engine command causes a
    # persistent server stall. Remove only clients identified as bots, leaving
    # all human clients untouched.
    my $slots = active_bot_slots();
    return 0 unless defined $slots;
    return 0 unless @$slots;
    debug('Removing bot slot(s): ' . join(', ', @$slots));
    rcon("clientkick $_") for @$slots;
    return scalar @$slots;
}

sub choose_bots {
    my ($amount, $excluded_characters) = @_;
    $amount = $opt{min_botplayer} unless defined $amount;
    # Fisher-Yates: different bots, reshuffled for every draw.
    my @shuffled = grep { !$excluded_characters || !$excluded_characters->{ $_->{character} } } @BOTS;
    for (my $i = $#shuffled; $i > 0; --$i) {
        my $j = int rand($i + 1);
        @shuffled[$i, $j] = @shuffled[$j, $i];
    }
    $amount = scalar @shuffled if $amount > @shuffled;
    return $amount ? @shuffled[0 .. $amount - 1] : ();
}

sub install_bots {
    my ($setting, $bots_already_removed, @selected_bots) = @_;
    my $humans = active_humans();
    $humans = 0 unless defined $humans;
    # Maintain the configured minimum after the human-player reduction.
    my $wanted = desired_bot_count($setting, $humans);
    my $free_slots = $setting->{max_players} - $humans;
    $wanted = $free_slots if $wanted > $free_slots;
    $wanted = scalar @selected_bots if $wanted > @selected_bots;
    my @bots_to_add = $wanted ? @selected_bots[0 .. $wanted - 1] : ();
    print "Bots: $humans human players, adding $wanted newly selected bots.\n";
    debug('Selected bots: ' . join(', ', map { $_->{character} } @selected_bots));
    disable_automatic_bots();
    remove_all_bots() unless $bots_already_removed;
    for my $bot (@bots_to_add) {
        my $skill = skill_for_bot($bot);
        $skill = 1 if $skill < 1;
        $skill = 5 if $skill > 5;
        my $cmd = join ' ', 'addbot', quote_q3($bot->{character}), $skill,
            quote_q3($bot->{team}), int($bot->{delay_ms}), quote_q3($bot->{model});
        rcon($cmd);
    }
    # addbot uses delayed joins. Check after they have connected and remove a
    # duplicate alias if an external or delayed bot join raced this install.
    sleep(1);
    remove_duplicate_managed_bots();
}

sub choose_map {
    my ($last_map, $rotation) = @_;
    $rotation //= $active_rotation;
    die "Unknown active rotation: $rotation\n" unless exists $ROTATIONS{$rotation};
    my @maps = @{ $ROTATIONS{$rotation} };
    my %recent = map { $_ => 1 } @recent_maps;
    my @candidates = grep { $_ ne ($last_map // '') && !$recent{$_} } @maps;
    @candidates = grep { $_ ne ($last_map // '') } @maps unless @candidates;
    @candidates = @maps unless @candidates;
    return $candidates[int rand @candidates];
}

sub schedule_random_nextmap {
    my ($current_map, $rotation) = @_;
    $rotation //= $active_rotation;
    my $next_map = choose_map($current_map, $rotation);
    set_scheduled_nextmap($next_map);
    debug("Scheduled nextmap $next_map from $rotation only.");
    return $next_map;
}

sub set_scheduled_nextmap {
    my ($next_map) = @_;
    # Smoking Guns executes this value through vstr nextmap after a map end.
    rcon('set nextmap ' . quote_q3('map ' . $next_map));
    $scheduled_next_map = $next_map;
}

sub current_map {
    my $status = server_status();
    return $1 if $status =~ /^map:\s*([^\s\r\n]+)/mi;
    debug('Could not read the current map from status.');
    return undef;
}

sub finish_current_map {
    my ($map, $reason) = @_;
    return unless defined $current_map_started_at;
    my $ended_at = time;
    my $duration = int($ended_at - $current_map_started_at);
    log_map_history('end', $ended_at, $map, $duration, $reason);
    debug("Map $map ended at " . timestamp($ended_at) . " (duration ${duration}s; reason: $reason)");
    undef $current_map_started_at;
}

sub active_bot_slots {
    my $status = server_status();
    # Do not accidentally create new bots after an RCON or network error.
    return undef unless $status =~ /^map:\s*/mi;
    my @slots;
    for my $line (split /\n/, $status) {
        next unless $line =~ /^\s*(\d+)\s+/;
        # The second regex would reset $1; save the slot immediately.
        my $slot = $1;
        push @slots, $slot if is_bot_status_line($line);
    }
    debug('Detected bot clients: ' . scalar @slots . ' (slots: ' . join(', ', @slots) . ')');
    return \@slots;
}

sub strip_q3_colors {
    my ($text) = @_;
    $text //= '';
    $text =~ s/\^[0-9]//g;
    return $text;
}

sub active_bot_characters {
    my $status = server_status();
    # Do not treat an unavailable RCON response as an empty bot list. Doing so
    # could select an alias that is already active.
    unless ($status =~ /^map:\s*/mi) {
        debug('Cannot identify active bot profiles; postponing bot refill.');
        return undef;
    }
    my %active;
    for my $line (split /\n/, $status) {
        next unless $line =~ /^\s*\d+\s+/ && is_bot_status_line($line);
        my $plain_line = strip_q3_colors($line);
        for my $bot (@BOTS) {
            my $plain_model = strip_q3_colors($bot->{model});
            if (index($line, $bot->{model}) >= 0 || index($plain_line, $plain_model) >= 0) {
                $active{ $bot->{character} } = 1;
            }
        }
    }
    debug('Active managed bot profiles: ' . join(', ', sort keys %active));
    return \%active;
}

sub unmanaged_bot_slots {
    my $status = server_status();
    return () unless $status =~ /^map:\s*/mi;
    my @slots;
    for my $line (split /\n/, $status) {
        next unless $line =~ /^\s*(\d+)\s+/;
        my $slot = $1;
        next unless is_bot_status_line($line);
        my $plain_line = strip_q3_colors($line);
        my $managed = 0;
        for my $bot (@BOTS) {
            my $plain_model = strip_q3_colors($bot->{model});
            if (index($line, $bot->{model}) >= 0 || index($plain_line, $plain_model) >= 0) {
                $managed = 1;
                last;
            }
        }
        push @slots, $slot unless $managed;
    }
    return @slots;
}

sub remove_unmanaged_bots {
    my @slots = unmanaged_bot_slots();
    return 0 unless @slots;
    debug('Removing unmanaged bot slot(s): ' . join(', ', @slots));
    rcon("clientkick $_") for @slots;
    return scalar @slots;
}

sub duplicate_managed_bot_slots {
    my $status = server_status();
    return () unless $status =~ /^map:\s*/mi;
    my %slots_by_character;
    for my $line (split /\n/, $status) {
        next unless $line =~ /^\s*(\d+)\s+/;
        my $slot = $1;
        next unless is_bot_status_line($line);
        my $plain_line = strip_q3_colors($line);
        for my $bot (@BOTS) {
            my $plain_model = strip_q3_colors($bot->{model});
            if (index($line, $bot->{model}) >= 0 || index($plain_line, $plain_model) >= 0) {
                push @{ $slots_by_character{ $bot->{character} } }, $slot;
                last;
            }
        }
    }

    my @duplicates;
    for my $character (sort keys %slots_by_character) {
        my @slots = sort { $a <=> $b } grep { defined $_ } @{ $slots_by_character{$character} };
        # Keep the oldest client slot and remove every later duplicate. Smoking
        # Guns adds an asterisk to the visible name for these duplicate joins.
        push @duplicates, @slots[1 .. $#slots] if @slots > 1;
    }
    return @duplicates;
}

sub remove_duplicate_managed_bots {
    my @slots = duplicate_managed_bot_slots();
    return 0 unless @slots;
    debug('Removing duplicate managed bot slot(s): ' . join(', ', @slots));
    rcon("clientkick $_") for @slots;
    return scalar @slots;
}

sub set_active_bot_count {
    my ($desired) = @_;
    # Apply ?setbots immediately. This function never removes human clients.
    my $bot_slots = active_bot_slots();
    return undef unless defined $bot_slots;

    my $current = scalar @$bot_slots;
    if ($current > $desired) {
        my $excess = $current - $desired;
        my @kick_slots = (sort { $b <=> $a } @$bot_slots)[0 .. $excess - 1];
        debug("?setbots removing $excess excess bot(s).");
        rcon("clientkick $_") for @kick_slots;
        return $desired;
    }
    return $current if $current == $desired;

    my $setting = settings_for_map($last_map);
    my $humans = active_humans();
    return undef unless defined $humans;
    my $free_slots = $setting->{max_players} - $humans - $current;
    $free_slots = 0 if $free_slots < 0;
    my $to_add = $desired - $current;
    $to_add = $free_slots if $to_add > $free_slots;
    $to_add = scalar @BOTS if $to_add > @BOTS;
    return $current unless $to_add > 0;

    # Do not add a second instance of any bot profile that is already playing.
    my $active_characters = active_bot_characters();
    return undef unless defined $active_characters;
    my @new_bots = choose_bots($to_add, $active_characters);
    debug('?setbots adding: ' . join(', ', map { $_->{character} } @new_bots));
    for my $bot (@new_bots) {
        my $skill = skill_for_bot($bot);
        $skill = 1 if $skill < 1;
        $skill = 5 if $skill > 5;
        my $cmd = join ' ', 'addbot', quote_q3($bot->{character}), $skill,
            quote_q3($bot->{team}), int($bot->{delay_ms}), quote_q3($bot->{model});
        rcon($cmd);
    }
    return $current + scalar @new_bots;
}

sub process_panel_command_file {
    my $file = $opt{command_file};
    unless (-e $file) {
        open my $create, '>>', $file or do {
            debug("Cannot create panel command file: $!");
            return;
        };
        close $create;
    }
    my $size = -s $file;
    if (!defined $command_file_position) {
        $command_file_position = $size;
        debug("Watching trusted panel commands from offset $command_file_position: $file");
        return;
    }
    if ($size < $command_file_position) {
        debug('Panel command file was rotated or truncated; reading from its beginning.');
        $command_file_position = 0;
    }
    open my $commands, '<:raw', $file or do {
        debug("Cannot open panel command file: $!");
        return;
    };
    seek $commands, $command_file_position, 0;
    while (my $line = <$commands>) {
        $line =~ s/[\r\n]+\z//;
        next unless $line =~ /^(?:([a-f0-9]{32})\t)?\?([A-Za-z][A-Za-z0-9_]*)(?:\s+([A-Za-z0-9_ -]+))?\s*\z/;
        my ($request_id, $command, $arguments) = ($1, lc $2, $3 // '');
        $panel_request_id = $request_id;
        unless (exists $opt{command_admin_guids}{$command}) {
            debug("Ignored unknown trusted panel command ?$command.");
            record_panel_response("Unknown BotC command ?$command");
            undef $panel_request_id;
            next;
        }
        debug("Executing trusted panel command ?$command $arguments");
        execute_controller_command($command, $arguments, "panel: ?$command $arguments");
        record_panel_response("^2Panel:^7 ?$command processed by BotC v$CONTROLLER_VERSION");
        undef $panel_request_id;
    }
    $command_file_position = tell $commands;
    close $commands;
}

sub nextmap_vote_passed {
    # Read only newly appended log lines. On first run, seek to the end so an
    # older vote is not acted on again.
    my $file = $opt{game_log_file};
    unless (-e $file) {
        debug("Server log not found: $file");
        return 0;
    }
    my $size = -s $file;
    if (!defined $game_log_position) {
        $game_log_position = $size;
        debug("Watching server log from offset $game_log_position: $file");
    }
    if ($size < $game_log_position) {
        # Log rotation or truncation.
        debug('Server log was rotated or truncated; reading from its beginning.');
        $game_log_position = 0;
        $nextmap_vote_active = 0;
    }

    open my $log, '<:raw', $file or do {
        debug("Cannot open server log: $!");
        return 0;
    };
    seek $log, $game_log_position, 0;
    my $passed = 0;
    while (my $line = <$log>) {
        update_client_team_from_log_line($line);
        if ($line =~ /\bExit:\s*Fraglimit hit\./i && defined $scheduled_next_map) {
            # Reassert the target immediately before Smoking Guns executes
            # vstr nextmap at the end of the intermission.
            set_scheduled_nextmap($scheduled_next_map);
            debug("Fraglimit exit detected; reasserted nextmap $scheduled_next_map.");
        }
        if ($line =~ /\?/ && command_allowed($line)) {
            process_controller_command($line);
        }
        # Smoking Guns logs the name and the actual vote command, e.g.
        # "Callvote: TFC: vstr nextmap".
        if ($line =~ /\bCallvote:\s*.*?\bvstr\s+nextmap\b/i) {
            $nextmap_vote_active = 1;
            # On success, the server runs "vstr nextmap". Set a random target
            # at the start of the vote so the server performs exactly one map change.
            $vote_target_map = choose_map($last_map, $active_rotation);
            set_scheduled_nextmap($vote_target_map);
            debug("nextmap vote detected in server log; random vote target: $vote_target_map.");
        }
        elsif ($line =~ /\bCallvote:\s*/i) {
            # A different vote replaces the previously tracked nextmap vote.
            $nextmap_vote_active = 0;
        }
        # Depending on the Smoking Guns version, this may read "Vote passed.",
        # "Vote passed!", or "Vote was passed.".
        if ($line =~ /\bVote\b.*\bpassed\b/i) {
            if ($nextmap_vote_active) {
                $passed = 1;
                (my $vote_line = $line) =~ s/[\r\n]+\z//;
                debug("nextmap vote passed: $vote_line");
            }
            $nextmap_vote_active = 0;
        }
        elsif ($line =~ /\bVote\b.*\b(?:failed|cancelled)\b/i) {
            $nextmap_vote_active = 0;
        }
    }
    $game_log_position = tell $log;
    close $log;
    return 1 if $passed;
    return console_nextmap_vote_passed();
}

sub console_nextmap_vote_passed {
    # The game log records the vote call, while the successful vote result is
    # emitted only through the console output on this server installation.
    my $file = $opt{console_log_file};
    unless (-e $file) {
        debug("Console log not found: $file");
        return 0;
    }
    my $size = -s $file;
    if (!defined $console_log_position) {
        $console_log_position = $size;
        debug("Watching console log from offset $console_log_position: $file");
        return 0;
    }
    if ($size < $console_log_position) {
        debug('Console log was rotated or truncated; reading from its beginning.');
        $console_log_position = 0;
        $nextmap_vote_active = 0;
    }

    open my $log, '<:raw', $file or do {
        debug("Cannot open console log: $!");
        return 0;
    };
    seek $log, $console_log_position, 0;
    my $passed = 0;
    while (my $line = <$log>) {
        if ($line =~ /\bVote\b.*\bpassed\b/i) {
            if ($nextmap_vote_active) {
                $passed = 1;
                (my $vote_line = $line) =~ s/[\r\n]+\z//;
                debug("nextmap vote passed in console log: $vote_line");
            }
            $nextmap_vote_active = 0;
        }
        elsif ($line =~ /\bVote\b.*\b(?:failed|cancelled)\b/i) {
            $nextmap_vote_active = 0;
        }
    }
    $console_log_position = tell $log;
    close $log;
    return $passed;
}

sub start_round {
    my ($map) = @_;
    my $setting = settings_for_map($map);
    my @selected_bots = choose_bots($setting->{min_botplayer});
    print "Starting randomly selected map: $map (frag limit $setting->{fraglimit}, time $setting->{timelimit_minutes} min)\n";
    # Remove old bots before the server loads the new map. This prevents them
    # from carrying over to the new map even with mod-specific behavior.
    remove_all_bots();
    prepare_map($map);
    configure_map($setting);
    rcon('map ' . quote_q3($map));
    $current_map_started_at = time;
    remember_map($map);
    log_map_history('start', $current_map_started_at, $map, undef, undef);
    debug("Map $map started at " . timestamp($current_map_started_at));
    sleep($setting->{map_load_wait_ms} / 1000);
    # install_bots performs the single post-load cleanup before adding bots.
    install_bots($setting, 0, @selected_bots);
    my $humans = active_humans();
    apply_human_timelimit_policy($setting, $humans) if defined $humans;
    schedule_random_nextmap($map, $active_rotation);
    announce_controller();
    return time + ($setting->{timelimit_minutes} * 60);
}

sub adopt_started_map {
    my ($map) = @_;
    # The map was already started by a successful player vote or an admin.
    # Do not send a second `map`; only apply rules and newly selected bots.
    my $setting = settings_for_map($map);
    my @selected_bots = choose_bots($setting->{min_botplayer});
    debug("Taking over already started map $map; selecting new bots.");
    # Bots may carry over briefly after a native vote or external map command.
    # Remove their individual slots before applying further RCON settings.
    remove_all_bots();
    configure_map($setting);
    install_bots($setting, 1, @selected_bots);
    my $humans = active_humans();
    apply_human_timelimit_policy($setting, $humans) if defined $humans;
    schedule_random_nextmap($map, $active_rotation);
    announce_controller();
    $current_map_started_at = time;
    remember_map($map);
    log_map_history('start', $current_map_started_at, $map, undef, 'adopted vote/admin map');
    debug("Map $map adopted as a vote/admin map at " . timestamp($current_map_started_at));
    return time + ($setting->{timelimit_minutes} * 60);
}

# A script restart must not force a new map. Take over the active map reported
# through RCON and only apply bots and limits. If the server is not ready yet,
# keep waiting rather than exit or start a map.
load_bot_skill_file();
load_client_teams_from_game_log();
my $initial_map;
while (!defined $initial_map) {
    $initial_map = current_map();
    if (!defined $initial_map) {
        debug('No active map reported through RCON status; retrying.');
        sleep($opt{poll_seconds});
    }
}
$last_map = $initial_map;
if (my $detected_rotation = rotation_for_map($last_map, $active_rotation)) {
    $active_rotation = $detected_rotation;
}
debug("Script restart detected; taking over active map $last_map without restarting it.");
$next_change_at = adopt_started_map($last_map);
exit 0 if $opt{once};
process_panel_command_file();

while (1) {
    sleep($opt{poll_seconds});
    # Each poll starts with exactly one fresh server status snapshot. All map,
    # player, and bot checks below reuse it unless an RCON command changes state.
    clear_status_snapshot();
    record_ping_samples();
    expire_custom_vote();
    process_panel_command_file();

    if (nextmap_vote_passed()) {
        # Do not send `map`: the server now executes vstr nextmap itself.
        # This changes the map once rather than twice.
        $awaiting_vote_map_switch = 1;
        debug("nextmap vote passed; waiting for the server to change to $vote_target_map.");
        next;
    }

    my $running_map = current_map();

    # A frag limit, player vote, admin, or server-side nextmap rotation can
    # change the map before the time limit. Take over that started map instead
    # of replacing it with another random map, and still select new bots.
    if (defined $running_map && $running_map ne $last_map) {
        debug("Map change detected: $last_map -> $running_map");
        my $reason = $awaiting_vote_map_switch
            ? 'passed callvote nextmap'
            : "server-side change to $running_map";
        finish_current_map($last_map, $reason);
        if ($awaiting_vote_map_switch && defined $vote_target_map && $running_map ne $vote_target_map) {
            debug("Vote target was $vote_target_map, but the server started $running_map.");
        }
        $awaiting_vote_map_switch = 0;
        undef $vote_target_map;
        $last_map = $running_map;
        if (my $detected_rotation = rotation_for_map($last_map, $active_rotation)) {
            $active_rotation = $detected_rotation;
        }
        $next_change_at = adopt_started_map($last_map);
        next;
    }

    my $time_setting = settings_for_map($last_map);
    my $time_humans = active_humans();
    next unless defined $time_humans;
    if (apply_human_timelimit_policy($time_setting, $time_humans)) {
        # Bot-only play begins with a new full time limit.
        $next_change_at = time + ($time_setting->{timelimit_minutes} * 60);
    }

    if ($time_humans == 0 && time >= $next_change_at) {
        debug("Controller time limit reached.");
        finish_current_map($last_map, 'controller time limit');
        $last_map = choose_map($last_map);
        $next_change_at = start_round($last_map);
        next;
    }

    # If bots were removed by an admin command or mod error, replenish missing
    # bots without changing the map. bot_minplayers is disabled during map
    # setup and bot installation; do not send that RCON command every poll.
    # Avoiding this keeps the current status snapshot valid and prevents an
    # unnecessary second status query on maps that are already under load.
    if (remove_unmanaged_bots()) {
        next;
    }
    if (remove_duplicate_managed_bots()) {
        next;
    }
    my $bot_slots = active_bot_slots();
    next unless defined $bot_slots;
    my $bot_count = scalar @$bot_slots;

    # If too many bots exist, remove the highest bot slots first. clientkick
    # affects only the specified bot client, never human players.
    if ($bot_count > $opt{max_bots}) {
        my $excess = $bot_count - $opt{max_bots};
        my @kick_slots = (sort { $b <=> $a } @$bot_slots)[0 .. $excess - 1];
        print "Too many bots ($bot_count/$opt{max_bots}); removing $excess bot(s).\n";
        for my $slot (@kick_slots) {
            debug("Removing excess bot in slot $slot");
            rcon("clientkick $slot");
        }
        next;
    }

    my $setting = settings_for_map($last_map);
    my $humans = active_humans();
    next unless defined $humans;
    my $free_slots = $setting->{max_players} - $humans;
    my $wanted = desired_bot_count($setting, $humans);
    $wanted = $free_slots if $wanted > $free_slots;
    if ($bot_count > $wanted) {
        my $excess = $bot_count - $wanted;
        my @kick_slots = (sort { $b <=> $a } @$bot_slots)[0 .. $excess - 1];
        print "Bot count is $bot_count/$wanted; removing $excess excess bot(s).\n";
        for my $slot (@kick_slots) {
            debug("Removing bot in slot $slot to reach the reduced target");
            rcon("clientkick $slot");
        }
        next;
    }
    if ($bot_count < $wanted) {
        my $missing = $wanted - $bot_count;
        print "Bot count is $bot_count/$wanted; adding $missing missing bot(s).\n";
        set_active_bot_count($wanted);
    }
}

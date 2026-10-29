# Smokin' Guns Bot Controller

Perl RCON controller for a Smokin' Guns dedicated server.

Current controller version: **1.0.76**.

## Included files

- `botc.pl` — map rotation, bot, voting, chat-command and optional statistics controller.
- `botskills.cfg` — individual bot profile skills.
- `rcon.cfg.example` — safe RCON configuration template.
- `database.cfg.example` — safe optional MySQL configuration template.

## Setup

1. Copy `rcon.cfg.example` to `rcon.cfg` and enter the server RCON password.
2. Optionally copy `database.cfg.example` to `database.cfg` for player and XLRstats commands.
3. Ensure Perl has the required modules, including `IO::Socket::INET`; MySQL commands additionally require `DBI` and `DBD::mysql`.
4. Start the controller from the server directory:

   ```sh
   perl botc.pl
   ```

Credentials and server logs are intentionally excluded from Git.

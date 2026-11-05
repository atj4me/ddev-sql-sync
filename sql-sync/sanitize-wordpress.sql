-- #ddev-generated: This file is managed by the sql-sync add-on (atj4me/ddev-sql-sync). To change the sanitize behaviour, point the alias's sanitize: key at your own SQL file instead of editing this one.
-- sql-sync sanitize for WordPress — run against the LOCAL database only, never on production.
-- Every user's email becomes user<id>@example.test and every password becomes "password".
-- user_pass is set to MD5('password'): WordPress accepts an MD5 hash at login and
-- transparently rehashes it to a modern hash on that user's first login.
-- Assumes the default wp_ table prefix.
UPDATE `wp_users`
SET `user_email` = CONCAT('user', `ID`, '@example.test'),
    `user_pass` = MD5('password');

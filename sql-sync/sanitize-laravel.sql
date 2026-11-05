-- #ddev-generated: This file is managed by the sql-sync add-on (atj4me/ddev-sql-sync). To change the sanitize behaviour, point the alias's sanitize: key at your own SQL file instead of editing this one.
-- sql-sync sanitize for Laravel — run against the LOCAL database only, never on production.
-- Every user's email becomes user<id>@example.test and every password becomes "password".
-- The hash below is a bcrypt hash of the literal string "password".
UPDATE `users`
SET `email` = CONCAT('user', `id`, '@example.test'),
    `password` = '$2y$12$6T4sYJL0JWcwgpy9fReET.Pm8.mEsMOtG99oSEDGTMdb8iIquupWq',
    `remember_token` = NULL;

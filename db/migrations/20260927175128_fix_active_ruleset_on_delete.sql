-- migrate:up
ALTER TABLE guild_active_ruleset
    DROP CONSTRAINT guild_active_ruleset_ruleset_id_fkey,
    ADD CONSTRAINT guild_active_ruleset_ruleset_id_fkey FOREIGN KEY (ruleset_id) REFERENCES rulesets(id)
        ON DELETE RESTRICT;

-- migrate:down

ALTER TABLE guild_active_ruleset
    DROP CONSTRAINT guild_active_ruleset_ruleset_id_fkey,
    ADD CONSTRAINT guild_active_ruleset_ruleset_id_fkey
         FOREIGN KEY (ruleset_id) REFERENCES rulesets(id)
            ON DELETE SET NULL;

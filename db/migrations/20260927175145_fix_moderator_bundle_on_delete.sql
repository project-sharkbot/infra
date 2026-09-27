-- migrate:up
ALTER TABLE moderator_user
    DROP CONSTRAINT moderator_user_mod_rules_id_fkey,
    ADD CONSTRAINT moderator_user_mod_rules_id_fkey
        FOREIGN KEY (mod_rules_id) REFERENCES mod_rules(id)
            ON DELETE CASCADE;

-- migrate:down

ALTER TABLE moderator_user
    DROP CONSTRAINT moderator_user_mod_rules_id_fkey,
    ADD CONSTRAINT moderator_user_mod_rules_id_fkey
        FOREIGN KEY (mod_rules_id) REFERENCES mod_rules(id);
        -- no ON DELETE CLAUSE for this migration

# frozen_string_literal: true

class GuardDiscussionBridgeGhostPolicyHistory < ActiveRecord::Migration[7.0]
  def up
    create_table :discussion_bridge_ghost_history_guards do |t|
      t.bigint :installation_id, null: false
      t.text :guard_key, null: false
      t.uuid :revision, null: false
    end
    add_index :discussion_bridge_ghost_history_guards,
              %i[installation_id guard_key],
              unique: true,
              name: "idx_db_ghost_history_guard"
    add_foreign_key :discussion_bridge_ghost_history_guards,
                    :discussion_bridge_ghost_installations,
                    column: :installation_id

    # Database enforced, including raw SQL and bulk ORM mutation. A fresh UUID
    # prevents an old proof becoming valid again after delete/recreate (ABA).
    # These are mutation sentinels, not checksums against privileged trigger
    # bypass or physical storage corruption outside PostgreSQL's guarantees.
    execute <<~SQL
      CREATE FUNCTION discussion_bridge_ghost_history_group(kind text, locator text)
      RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
      BEGIN
        IF kind = 'policy_history_page' THEN
          IF locator !~ '^[a-f0-9-]{36}:[a-f0-9]{64}:[0-9]{16}:[0-9]{16}$' THEN
            RAISE EXCEPTION 'Invalid retained history page locator';
          END IF;
          RETURN 'pages:' || left(locator, length(locator) - 17);
        ELSIF kind = 'policy_history_revision_v2' THEN
          IF locator !~ '^[a-f0-9-]{36}:[a-f0-9]{64}:[0-9]{16}:[a-f0-9-]{36}:[a-f0-9]{64}$' THEN
            RAISE EXCEPTION 'Invalid retained history revision locator';
          END IF;
          RETURN 'revisions:' || left(locator, length(locator) - 65);
        END IF;
        RETURN NULL;
      END;
      $$;

      CREATE FUNCTION discussion_bridge_ghost_history_changed()
      RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        old_installation bigint;
        new_installation bigint;
        old_group text;
        new_group text;
        affected record;
      BEGIN
        IF TG_OP <> 'INSERT' THEN
          old_installation := OLD.installation_id;
          old_group := discussion_bridge_ghost_history_group(OLD.kind, OLD.record_key);
        END IF;
        IF TG_OP <> 'DELETE' THEN
          new_installation := NEW.installation_id;
          new_group := discussion_bridge_ghost_history_group(NEW.kind, NEW.record_key);
        END IF;
        FOR affected IN
          SELECT DISTINCT installation, guard_key FROM
            (VALUES (old_installation, old_group), (new_installation, new_group)) AS groups(installation, guard_key)
          WHERE guard_key IS NOT NULL ORDER BY installation, guard_key
        LOOP
          INSERT INTO discussion_bridge_ghost_history_guards(installation_id, guard_key, revision)
            VALUES (affected.installation, affected.guard_key, gen_random_uuid())
          ON CONFLICT (installation_id, guard_key)
            DO UPDATE SET revision = gen_random_uuid();
        END LOOP;
        RETURN NULL;
      END;
      $$;

      CREATE TRIGGER discussion_bridge_ghost_history_changed
      AFTER INSERT OR UPDATE OR DELETE ON discussion_bridge_ghost_records
      FOR EACH ROW EXECUTE FUNCTION discussion_bridge_ghost_history_changed();

      CREATE FUNCTION discussion_bridge_ghost_history_truncated()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        UPDATE discussion_bridge_ghost_history_guards SET revision = gen_random_uuid();
        RETURN NULL;
      END;
      $$;

      CREATE TRIGGER discussion_bridge_ghost_history_truncated
      AFTER TRUNCATE ON discussion_bridge_ghost_records
      FOR EACH STATEMENT EXECUTE FUNCTION discussion_bridge_ghost_history_truncated();

      INSERT INTO discussion_bridge_ghost_history_guards(installation_id, guard_key, revision)
        SELECT DISTINCT installation_id, discussion_bridge_ghost_history_group(kind, record_key), gen_random_uuid()
        FROM discussion_bridge_ghost_records WHERE kind = 'policy_history_page'
        ON CONFLICT (installation_id, guard_key) DO NOTHING;
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER discussion_bridge_ghost_history_truncated ON discussion_bridge_ghost_records;
      DROP TRIGGER discussion_bridge_ghost_history_changed ON discussion_bridge_ghost_records;
      DROP FUNCTION discussion_bridge_ghost_history_truncated();
      DROP FUNCTION discussion_bridge_ghost_history_changed();
      DROP FUNCTION discussion_bridge_ghost_history_group(text, text);
    SQL
    drop_table :discussion_bridge_ghost_history_guards
  end
end

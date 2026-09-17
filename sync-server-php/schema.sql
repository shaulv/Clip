-- Clip sync: schema.
--
-- There are no accounts here. A *space* is a pool of synced data, addressed by
-- one token, and holding the token is the whole of the authorisation.
--
-- Storage limits are deliberately absent. The one that matters is the column
-- type: `payload` is LONGTEXT rather than TEXT, because a rich-text clip carries
-- its RTF as base64 and passes TEXT's 64 KB without trying. Under MySQL's
-- default non-strict mode an over-long TEXT is *silently truncated*, so the
-- write succeeds, the sync reports success, and the clip comes back corrupted.

SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS spaces (
    id                    VARCHAR(64)  NOT NULL,
    created_at            DOUBLE       NOT NULL,
    -- 0 locks the space: no device it does not already know may join.
    shared                TINYINT(1)   NOT NULL DEFAULT 1,
    deletion_requested_at DOUBLE       NULL,
    purge_at              DOUBLE       NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Only the hash is stored, so the database alone opens nothing.
CREATE TABLE IF NOT EXISTS tokens (
    token_hash CHAR(64)    NOT NULL,
    space_id   VARCHAR(64) NOT NULL,
    created_at DOUBLE      NOT NULL,
    PRIMARY KEY (token_hash),
    KEY tokens_space (space_id),
    CONSTRAINT tokens_space_fk FOREIGN KEY (space_id)
        REFERENCES spaces(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS devices (
    space_id  VARCHAR(64)  NOT NULL,
    device_id VARCHAR(128) NOT NULL,
    name      VARCHAR(255) NULL,
    last_seen DOUBLE       NOT NULL,
    PRIMARY KEY (space_id, device_id),
    CONSTRAINT devices_space_fk FOREIGN KEY (space_id)
        REFERENCES spaces(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS records (
    space_id   VARCHAR(64)  NOT NULL,
    entity     VARCHAR(32)  NOT NULL,
    id         VARCHAR(64)  NOT NULL,
    updated_at DOUBLE       NOT NULL,
    deleted    TINYINT(1)   NOT NULL DEFAULT 0,
    -- 4 GiB. See the note at the top: this is the limit that bites silently.
    payload    LONGTEXT     NULL,
    seq        BIGINT       NOT NULL DEFAULT 0,
    PRIMARY KEY (space_id, entity, id),
    KEY records_seq (space_id, seq),
    CONSTRAINT records_space_fk FOREIGN KEY (space_id)
        REFERENCES spaces(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS counters (
    space_id VARCHAR(64) NOT NULL,
    seq      BIGINT      NOT NULL DEFAULT 0,
    PRIMARY KEY (space_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Creating a space is unauthenticated on purpose: requiring an identity to get
-- an empty pool would put back the sign-in step this design removes. That makes
-- it the one endpoint worth rate limiting.
CREATE TABLE IF NOT EXISTS throttle (
    ip       VARCHAR(45) NOT NULL,
    window   BIGINT      NOT NULL,
    hits     INT         NOT NULL DEFAULT 0,
    PRIMARY KEY (ip, window)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Sign in with Google.
--
-- An account does not replace a token: it *owns* one. Everything downstream -
-- claim, sync, sharing, deletion - keeps working unchanged, and a user who
-- signs out can still reach their data by pasting the token.
--
-- `subject` is Google's `sub` claim, not the email. An address can be changed
-- and re-assigned; `sub` is stable for the life of the account, and keying on
-- the email would hand someone else's data to whoever inherits the address.
--
-- The token is stored in full here, unlike a pasted one, which is stored only
-- as a hash. That is the price of "sign in on a new Mac and everything is
-- there": the server has to be able to hand the token back, and it cannot do
-- that from a hash. Reaching it requires a signed, unexpired, audience-matched
-- Google identity for that exact subject.
CREATE TABLE IF NOT EXISTS google_accounts (
    subject    VARCHAR(64)  NOT NULL,
    email      VARCHAR(320) NULL,
    space_id   VARCHAR(64)  NOT NULL,
    token      VARCHAR(64)  NOT NULL,
    created_at DOUBLE       NOT NULL,
    last_seen  DOUBLE       NOT NULL,
    PRIMARY KEY (subject),
    KEY google_space (space_id),
    CONSTRAINT google_space_fk FOREIGN KEY (space_id)
        REFERENCES spaces(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

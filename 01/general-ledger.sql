CREATE TABLE chart_of_accounts (
  account_id     VARCHAR(10)  PRIMARY KEY,
  account_name   VARCHAR(100) NOT NULL UNIQUE,
  normal_balance VARCHAR(6)   NOT NULL CHECK (normal_balance IN ('DEBIT','CREDIT')),
  report_class   VARCHAR(10)  NOT NULL CHECK (report_class IN ('NERACA','LABA_RUGI'))
);

CREATE TABLE journal_headers (
  id             BIGSERIAL    PRIMARY KEY,
  trx_date       DATE         NOT NULL,
  ref_no         VARCHAR(30)  NOT NULL UNIQUE,
  description    TEXT         NOT NULL,
  posting_status VARCHAR(10)  NOT NULL DEFAULT 'DRAFT'
                 CHECK (posting_status IN ('DRAFT','POSTED')),
  -- kolom audit (dipakai di Soal 3.2)
  reversal_of    BIGINT REFERENCES journal_headers(id) ON DELETE RESTRICT,
  created_by     VARCHAR(100) NOT NULL DEFAULT current_user,
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
  posted_at      TIMESTAMPTZ,
  prev_hash      CHAR(64),
  hash_checksum  CHAR(64)
);
CREATE UNIQUE INDEX ux_one_reversal ON journal_headers(reversal_of) WHERE reversal_of IS NOT NULL;

CREATE TABLE journal_lines (
  id         BIGSERIAL     PRIMARY KEY,
  header_id  BIGINT        NOT NULL REFERENCES journal_headers(id)
                           ON DELETE RESTRICT,
  account_id VARCHAR(10)   NOT NULL REFERENCES chart_of_accounts(account_id)
                           ON DELETE RESTRICT,
  debit      NUMERIC(18,2) NOT NULL DEFAULT 0,
  credit     NUMERIC(18,2) NOT NULL DEFAULT 0,
  CONSTRAINT chk_non_negative  CHECK (debit >= 0 AND credit >= 0),
  CONSTRAINT chk_not_both_zero CHECK (NOT (debit = 0 AND credit = 0))
);
CREATE INDEX ix_lines_header ON journal_lines(header_id);

-- Constraint trigger: total debit = total kredit, dicek saat COMMIT
CREATE OR REPLACE FUNCTION fn_check_journal_balanced() RETURNS trigger AS $$
DECLARE v_header BIGINT; v_d NUMERIC; v_c NUMERIC;
BEGIN
  IF TG_OP = 'DELETE' THEN v_header := OLD.header_id; ELSE v_header := NEW.header_id; END IF;
  SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0) INTO v_d, v_c
  FROM journal_lines WHERE header_id = v_header;
  IF v_d <> v_c THEN
    RAISE EXCEPTION 'Jurnal % tidak seimbang: debit=% kredit=%', v_header, v_d, v_c
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER ctrg_journal_balanced
AFTER INSERT OR UPDATE OR DELETE ON journal_lines
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_check_journal_balanced();

-- Data akun contoh (dipakai Soal 2 dan 3)
INSERT INTO chart_of_accounts VALUES
 ('1-1100','Kas','DEBIT','NERACA'),
 ('1-1200','Bank','DEBIT','NERACA'),
 ('1-1300','Persediaan Barang Dagang','DEBIT','NERACA'),
 ('2-1100','Utang Usaha','CREDIT','NERACA'),
 ('5-1000','Beban Pokok Pendapatan (HPP)','DEBIT','LABA_RUGI'),
 ('5-2100','Beban Gaji','DEBIT','LABA_RUGI'),
 ('5-2200','Beban Sewa','DEBIT','LABA_RUGI'),
 ('5-2300','Beban Listrik dan Air','DEBIT','LABA_RUGI');

-- UJI: jurnal tidak seimbang harus GAGAL saat COMMIT
-- BEGIN;
-- INSERT INTO journal_headers(trx_date, ref_no, description) VALUES (CURRENT_DATE,'T-001','uji');
-- INSERT INTO journal_lines(header_id, account_id, debit, credit) VALUES (1,'5-2200',100,0),(1,'1-1200',0,90);
-- COMMIT;   -- ERROR: Jurnal 1 tidak seimbang

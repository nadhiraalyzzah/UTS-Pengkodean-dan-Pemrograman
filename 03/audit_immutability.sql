CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
-- Jika di PostgreSQL biasa (bukan Supabase) dan error schema 'extensions':
--   CREATE SCHEMA IF NOT EXISTS extensions;  lalu ulangi baris di atas.

-- (1) Kunci jurnal POSTED
CREATE OR REPLACE FUNCTION fn_block_posted_header() RETURNS trigger AS $$
BEGIN
  IF OLD.posting_status = 'POSTED' THEN
    RAISE EXCEPTION 'Jurnal % berstatus POSTED: % ditolak. Gunakan jurnal pembalik.', OLD.ref_no, TG_OP
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_block_posted_header
BEFORE UPDATE OR DELETE ON journal_headers
FOR EACH ROW EXECUTE FUNCTION fn_block_posted_header();

CREATE OR REPLACE FUNCTION fn_block_posted_lines() RETURNS trigger AS $$
DECLARE v_status TEXT;
BEGIN
  SELECT posting_status INTO v_status FROM journal_headers
  WHERE id = CASE WHEN TG_OP = 'INSERT' THEN NEW.header_id ELSE OLD.header_id END;
  IF v_status = 'POSTED' THEN
    RAISE EXCEPTION 'Baris jurnal POSTED tidak dapat di-%. Gunakan jurnal pembalik.', TG_OP
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_block_posted_lines
BEFORE INSERT OR UPDATE OR DELETE ON journal_lines
FOR EACH ROW EXECUTE FUNCTION fn_block_posted_lines();

-- (2) Cabut hak langsung dari klien (peran bawaan Supabase).
-- Di PostgreSQL biasa, peran anon/authenticated tidak ada: lewati blok ini.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
     AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'REVOKE UPDATE, DELETE ON journal_headers, journal_lines FROM anon, authenticated';
  END IF;
END $$;

-- Stempel audit tidak bisa dipalsukan klien
CREATE OR REPLACE FUNCTION fn_stamp_created() RETURNS trigger AS $$
BEGIN
  NEW.created_at     := now();
  NEW.created_by     := COALESCE(NULLIF(current_setting('request.jwt.claim.sub', true), ''), current_user);
  NEW.posting_status := 'DRAFT';
  NEW.posted_at := NULL; NEW.prev_hash := NULL; NEW.hash_checksum := NULL;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_stamp_created BEFORE INSERT ON journal_headers
FOR EACH ROW EXECUTE FUNCTION fn_stamp_created();

-- Hash kanonik: data header + seluruh baris + hash sebelumnya (rantai)
CREATE OR REPLACE FUNCTION fn_journal_hash(p_id BIGINT, p_prev TEXT) RETURNS TEXT
LANGUAGE sql STABLE SET search_path = public, extensions AS $$
  SELECT encode(digest(concat_ws('|', h.id, h.ref_no, h.trx_date, h.description, h.created_by,
           to_char(h.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
           COALESCE(p_prev, 'GENESIS'),
           (SELECT string_agg(l.account_id || ':' || l.debit || ':' || l.credit, ';' ORDER BY l.id)
              FROM journal_lines l WHERE l.header_id = h.id)), 'sha256'), 'hex')
  FROM journal_headers h WHERE h.id = p_id;
$$;

-- (3) RPC posting: DRAFT -> POSTED + hash
CREATE OR REPLACE FUNCTION fn_post_journal(p_id BIGINT) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_status TEXT; v_d NUMERIC; v_c NUMERIC; v_prev TEXT; v_hash TEXT;
BEGIN
  SELECT posting_status INTO v_status FROM journal_headers WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Jurnal % tidak ditemukan', p_id; END IF;
  IF v_status = 'POSTED' THEN RAISE EXCEPTION 'Jurnal % sudah POSTED', p_id; END IF;

  SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0) INTO v_d, v_c
  FROM journal_lines WHERE header_id = p_id;
  IF v_d = 0 OR v_d <> v_c THEN
    RAISE EXCEPTION 'Jurnal tidak seimbang atau kosong (D=%, K=%)', v_d, v_c;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('journal_hash_chain'));  -- serialkan rantai hash
  SELECT hash_checksum INTO v_prev FROM journal_headers
  WHERE posting_status = 'POSTED' ORDER BY posted_at DESC, id DESC LIMIT 1;

  v_hash := fn_journal_hash(p_id, v_prev);
  UPDATE journal_headers
     SET posting_status = 'POSTED', posted_at = now(), prev_hash = v_prev, hash_checksum = v_hash
   WHERE id = p_id;
  RETURN v_hash;
END $$;

-- (4) RPC jurnal pembalik (storno)
CREATE OR REPLACE FUNCTION fn_reverse_journal(p_id BIGINT, p_reason TEXT) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE o journal_headers%ROWTYPE; v_new BIGINT;
BEGIN
  SELECT * INTO o FROM journal_headers WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Jurnal % tidak ditemukan', p_id; END IF;
  IF o.posting_status <> 'POSTED' THEN RAISE EXCEPTION 'Hanya jurnal POSTED yang dapat dibalik'; END IF;

  INSERT INTO journal_headers(trx_date, ref_no, description, reversal_of)
  VALUES (CURRENT_DATE, 'REV-' || o.ref_no, 'Pembalik ' || o.ref_no || ': ' || p_reason, o.id)
  RETURNING id INTO v_new;          -- indeks unik ux_one_reversal mencegah storno ganda

  INSERT INTO journal_lines(header_id, account_id, debit, credit)
  SELECT v_new, account_id, credit, debit FROM journal_lines WHERE header_id = o.id ORDER BY id;

  PERFORM fn_post_journal(v_new);
  RETURN v_new;
END $$;

-- (5) Verifikasi integritas seluruh rantai
CREATE OR REPLACE FUNCTION fn_verify_chain()
RETURNS TABLE(out_id BIGINT, out_ref VARCHAR, out_ok BOOLEAN)
LANGUAGE sql STABLE SET search_path = public, extensions AS $$
  SELECT t.id, t.ref_no,
         (t.hash_checksum = fn_journal_hash(t.id, t.prev_hash))
         AND (t.prev_hash IS NOT DISTINCT FROM t.lag_hash)
  FROM (SELECT h.*, LAG(h.hash_checksum) OVER (ORDER BY h.posted_at, h.id) AS lag_hash
          FROM journal_headers h WHERE h.posting_status = 'POSTED') t
  ORDER BY t.posted_at, t.id;
$$;

-- Audit log append-only
CREATE TABLE audit_log (
  id BIGSERIAL PRIMARY KEY, table_name TEXT NOT NULL, record_id BIGINT,
  action TEXT NOT NULL, actor TEXT NOT NULL DEFAULT current_user,
  at TIMESTAMPTZ NOT NULL DEFAULT now(), detail JSONB
);
CREATE OR REPLACE FUNCTION fn_audit_header() RETURNS trigger AS $$
BEGIN
  INSERT INTO audit_log(table_name, record_id, action, detail)
  VALUES ('journal_headers', NEW.id, TG_OP || ':' || NEW.posting_status, to_jsonb(NEW));
  RETURN NULL;
END $$ LANGUAGE plpgsql SECURITY DEFINER;
CREATE TRIGGER trg_audit_header AFTER INSERT OR UPDATE ON journal_headers
FOR EACH ROW EXECUTE FUNCTION fn_audit_header();

CREATE OR REPLACE FUNCTION fn_append_only() RETURNS trigger AS $$
BEGIN RAISE EXCEPTION 'audit_log bersifat append-only'; END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_append_only BEFORE UPDATE OR DELETE ON audit_log
FOR EACH ROW EXECUTE FUNCTION fn_append_only();

-- ---------- UJI ----------
-- BEGIN;
-- INSERT INTO journal_headers(trx_date, ref_no, description) VALUES (CURRENT_DATE,'KK-2026-001','Sewa gudang');
-- INSERT INTO journal_lines(header_id, account_id, debit, credit)
--   SELECT id,'5-2200',5000000,0 FROM journal_headers WHERE ref_no='KK-2026-001';
-- INSERT INTO journal_lines(header_id, account_id, debit, credit)
--   SELECT id,'1-1200',0,5000000 FROM journal_headers WHERE ref_no='KK-2026-001';
-- SELECT fn_post_journal(id) FROM journal_headers WHERE ref_no='KK-2026-001';
-- COMMIT;
--
-- UPDATE journal_headers SET description='ubah' WHERE ref_no='KK-2026-001';  -- HARUS error
-- DELETE FROM journal_headers WHERE ref_no='KK-2026-001';                    -- HARUS error
-- SELECT fn_reverse_journal(id,'Salah akun') FROM journal_headers WHERE ref_no='KK-2026-001';
-- SELECT * FROM fn_verify_chain();   -- semua out_ok = true

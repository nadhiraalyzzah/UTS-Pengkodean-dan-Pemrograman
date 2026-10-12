-- Penanda akun kas dan klasifikasi arus kas (temuan 3.1b ditutup di database)
ALTER TABLE chart_of_accounts ADD COLUMN IF NOT EXISTS is_cash_account BOOLEAN NOT NULL DEFAULT FALSE;
UPDATE chart_of_accounts SET is_cash_account = TRUE WHERE account_id IN ('1-1100','1-1200');
ALTER TABLE journal_headers ADD COLUMN IF NOT EXISTS cash_flow_class VARCHAR(10)
  CHECK (cash_flow_class IN ('OPERASI','INVESTASI','PENDANAAN'));

-- created_by diambil dari identitas login (tidak bisa dipalsukan klien)
CREATE OR REPLACE FUNCTION fn_stamp_created() RETURNS trigger AS $$
BEGIN
  NEW.created_at     := now();
  NEW.created_by     := COALESCE(auth.uid()::text, current_user);
  NEW.posting_status := 'DRAFT';
  NEW.posted_at := NULL; NEW.prev_hash := NULL; NEW.hash_checksum := NULL;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

-- RPC tunggal: buat header + baris + validasi kas + posting, dalam satu transaksi
CREATE OR REPLACE FUNCTION fn_create_cash_voucher(
  p_date DATE, p_ref TEXT, p_desc TEXT, p_class TEXT, p_lines JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_id BIGINT; v_cash_credit NUMERIC; v_hash TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Harus login terlebih dahulu'; END IF;
  IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) < 2 THEN
    RAISE EXCEPTION 'Jurnal minimal 2 baris';
  END IF;

  INSERT INTO journal_headers(trx_date, ref_no, description, cash_flow_class)
  VALUES (p_date, p_ref, p_desc, upper(p_class)) RETURNING id INTO v_id;

  INSERT INTO journal_lines(header_id, account_id, debit, credit)
  SELECT v_id, x.account_id, COALESCE(x.debit,0), COALESCE(x.credit,0)
  FROM jsonb_to_recordset(p_lines) AS x(account_id TEXT, debit NUMERIC, credit NUMERIC);

  SELECT COALESCE(SUM(jl.credit),0) INTO v_cash_credit
  FROM journal_lines jl JOIN chart_of_accounts a ON a.account_id = jl.account_id
  WHERE jl.header_id = v_id AND a.is_cash_account;
  IF v_cash_credit <= 0 THEN
    RAISE EXCEPTION 'Voucher kas keluar harus mengkredit minimal satu akun kas atau bank';
  END IF;

  v_hash := fn_post_journal(v_id);   -- cek seimbang, hash berantai, status POSTED
  RETURN jsonb_build_object('id', v_id, 'ref_no', p_ref, 'hash_checksum', v_hash);
END $$;

ALTER FUNCTION fn_verify_chain() SECURITY DEFINER;

-- Row Level Security: klien hanya boleh MEMBACA; semua tulis lewat RPC
ALTER TABLE chart_of_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_headers   ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_lines     ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log         ENABLE ROW LEVEL SECURITY;
CREATE POLICY coa_read ON chart_of_accounts FOR SELECT TO authenticated USING (true);
CREATE POLICY hdr_read ON journal_headers   FOR SELECT TO authenticated USING (true);
CREATE POLICY lin_read ON journal_lines     FOR SELECT TO authenticated USING (true);
CREATE POLICY log_read ON audit_log         FOR SELECT TO authenticated USING (true);

REVOKE ALL ON chart_of_accounts, journal_headers, journal_lines, audit_log FROM anon, authenticated;
GRANT SELECT ON chart_of_accounts, journal_headers, journal_lines, audit_log TO authenticated;

-- Hak eksekusi fungsi: hanya pengguna login, dan hanya fungsi yang memang untuk klien
REVOKE ALL ON FUNCTION fn_create_cash_voucher(DATE,TEXT,TEXT,TEXT,JSONB), fn_reverse_journal(BIGINT,TEXT),
  fn_post_journal(BIGINT), fn_verify_chain() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION fn_create_cash_voucher(DATE,TEXT,TEXT,TEXT,JSONB), fn_reverse_journal(BIGINT,TEXT),
  fn_verify_chain() TO authenticated;

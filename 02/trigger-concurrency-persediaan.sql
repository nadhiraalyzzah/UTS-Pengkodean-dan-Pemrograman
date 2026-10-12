CREATE TABLE inventory_items (
    item_id VARCHAR(10) PRIMARY KEY,
    item_name VARCHAR(100),
    stock_qty INT NOT NULL DEFAULT 0,
    unit_cost NUMERIC(15, 2) NOT NULL
);

CREATE TABLE inventory_transactions (
    trx_id SERIAL PRIMARY KEY,
    item_id VARCHAR(10) REFERENCES inventory_items(item_id),
    trx_type VARCHAR(10) CHECK (trx_type IN ('PURCHASE', 'SALE', 'ADJUSTMENT')),
    qty INT NOT NULL,
    trx_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE inventory_items
  ADD CONSTRAINT chk_stock_nonneg CHECK (stock_qty >= 0);  -- lapis pertahanan terakhir

CREATE OR REPLACE FUNCTION trg_update_stock_and_journal()
RETURNS TRIGGER AS $$
DECLARE
  v_stock INT;
  v_delta INT;
BEGIN
  -- kunci baris item agar mutasi bersamaan antre (lihat 2.2)
  SELECT stock_qty INTO v_stock
  FROM inventory_items WHERE item_id = NEW.item_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Item % tidak ditemukan', NEW.item_id;
  END IF;

  IF NEW.trx_type IN ('PURCHASE','SALE') AND NEW.qty <= 0 THEN
    RAISE EXCEPTION 'Qty % tidak valid untuk %: harus > 0', NEW.qty, NEW.trx_type;
  END IF;

  v_delta := CASE NEW.trx_type
               WHEN 'PURCHASE' THEN  NEW.qty
               WHEN 'SALE'     THEN -NEW.qty
               ELSE                  NEW.qty      -- ADJUSTMENT bertanda
             END;

  -- (b) anti-negative inventory
  IF v_stock + v_delta < 0 THEN
    RAISE EXCEPTION 'Stok item % tidak cukup (tersedia %, diminta %)',
                    NEW.item_id, v_stock, -v_delta
      USING ERRCODE = 'check_violation';
  END IF;

  -- (a) mutasi stok
  UPDATE inventory_items SET stock_qty = stock_qty + v_delta
  WHERE item_id = NEW.item_id;

  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_inventory_after_insert
AFTER INSERT ON inventory_transactions
FOR EACH ROW EXECUTE FUNCTION trg_update_stock_and_journal();

-- ---------- UJI ----------
INSERT INTO inventory_items VALUES ('BRG001','Kopi 1 kg',0,50000);
INSERT INTO inventory_transactions(item_id,trx_type,qty) VALUES ('BRG001','PURCHASE',10); -- stok 10
INSERT INTO inventory_transactions(item_id,trx_type,qty) VALUES ('BRG001','SALE',3);      -- stok 7
-- Baris berikut HARUS error (stok tidak cukup); aktifkan untuk menguji:
-- INSERT INTO inventory_transactions(item_id,trx_type,qty) VALUES ('BRG001','SALE',8);
SELECT stock_qty FROM inventory_items WHERE item_id='BRG001';                              -- 7

-- ---------- 2.2 CONCURRENCY (contoh, jalankan di dua sesi terpisah) ----------
-- Sesi A dan B:
-- BEGIN;
-- SELECT stock_qty FROM inventory_items WHERE item_id = 'BRG001' FOR UPDATE;
-- INSERT INTO inventory_transactions(item_id, trx_type, qty) VALUES ('BRG001','SALE',1);
-- COMMIT;
--
-- Alternatif atomik:
-- UPDATE inventory_items SET stock_qty = stock_qty - 1
-- WHERE item_id = 'BRG001' AND stock_qty >= 1;
--
-- Alternatif SERIALIZABLE (ulangi transaksi bila SQLSTATE 40001):
-- BEGIN ISOLATION LEVEL SERIALIZABLE; ... COMMIT;

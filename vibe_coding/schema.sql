-- ============================================================
-- Simple Online Store (single-merchant) — Initial Schema (Postgres)
-- Includes:
--   • Option B: order_addresses snapshot table (immutable order addresses)
--   • variants: no inventory_quantity (inventory via inventory_levels only)
--   • products: no product-level SKU; SKU lives on variants
--   • customers.email NOT NULL + case-insensitive UNIQUE
--   • cart_items: quantity > 0; UNIQUE (cart_id, variant_id)
--   • orders.status & fulfillments.status enum-like checks
--   • orders: weight unit column; money as DECIMAL(10,2) everywhere
--   • payment_transactions: idempotency key (payment_method_transaction_id) with partial UNIQUE index
--   • products: visibility/availability flags
--   • carts.status enum + orders.cart_id UNIQUE FK
--   • Triggers: cart_items write-guard; auto-flip cart to ORDERED on order insert
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =========================
-- Taxonomy & Catalog
-- =========================

CREATE TABLE categories (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id    UUID REFERENCES categories(id),
  title        VARCHAR NOT NULL,
  handle       VARCHAR UNIQUE NOT NULL,
  description  TEXT,
  sort_order   INTEGER,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE collections (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title        VARCHAR NOT NULL,
  handle       VARCHAR UNIQUE NOT NULL,
  description  TEXT,
  sort_order   INTEGER,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE products (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id           UUID REFERENCES categories(id),
  name                  VARCHAR NOT NULL,
  handle                VARCHAR NOT NULL,
  description           TEXT,
  image_url             VARCHAR,
  is_published          BOOLEAN NOT NULL DEFAULT TRUE,
  availability_status   VARCHAR NOT NULL DEFAULT 'IN_STOCK',
  created_at            TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  tags                  TEXT
);
CREATE INDEX idx_products_name   ON products(name);
CREATE INDEX idx_products_handle ON products(handle);

ALTER TABLE products
  ADD CONSTRAINT chk_products_availability_status
  CHECK (UPPER(availability_status) IN ('IN_STOCK','OUT_OF_STOCK','DISCONTINUED'));

CREATE TABLE product_variants (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id         UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  title              VARCHAR,
  description        TEXT,
  image_url          VARCHAR,
  sku                VARCHAR,
  price              DECIMAL(10,2) NOT NULL,
  compare_at_price   DECIMAL(10,2),
  taxable            BOOLEAN NOT NULL DEFAULT TRUE,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_product_variants_product_id ON product_variants(product_id);
CREATE INDEX idx_product_variants_sku        ON product_variants(sku);

-- =========================
-- Customers & Addresses
-- =========================

CREATE TABLE customers (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  external_ref VARCHAR,
  email        VARCHAR NOT NULL,
  first_name   VARCHAR,
  last_name    VARCHAR,
  phone        VARCHAR,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- Case-insensitive unique email
CREATE UNIQUE INDEX uq_customers_email_lower ON customers (LOWER(email));

-- Reusable addresses for customers and inventory origins (NOT for orders)
CREATE TABLE addresses (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  addressable_id   UUID,        -- e.g., customers.id or NULL for standalone locations
  addressable_type VARCHAR,     -- 'CUSTOMER' | 'INVENTORY'
  address_type     VARCHAR,     -- 'BILLING' | 'SHIPPING' | 'ORIGIN'
  first_name       VARCHAR,
  last_name        VARCHAR,
  company          VARCHAR,
  phone            VARCHAR,
  line1            VARCHAR,
  line2            VARCHAR,
  city             VARCHAR,
  region           VARCHAR,
  postal_code      VARCHAR,
  country_code     VARCHAR,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
ALTER TABLE addresses
  ADD CONSTRAINT chk_addresses_address_type
  CHECK (address_type IS NULL OR UPPER(address_type) IN ('BILLING','SHIPPING','ORIGIN'));
ALTER TABLE addresses
  ADD CONSTRAINT chk_addresses_addressable_type
  CHECK (addressable_type IS NULL OR UPPER(addressable_type) IN ('CUSTOMER','INVENTORY'));

-- =========================
-- Inventory (per variant per location)
-- =========================

CREATE TABLE inventory_levels (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  variant_id           UUID NOT NULL REFERENCES product_variants(id) ON DELETE CASCADE,
  address_id           UUID REFERENCES addresses(id),  -- stock location
  inventory_quantity   INTEGER NOT NULL DEFAULT 0,
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX uq_inventory_levels_variant_location
  ON inventory_levels(variant_id, address_id);
ALTER TABLE inventory_levels
  ADD CONSTRAINT chk_inventory_levels_qty_nonneg CHECK (inventory_quantity >= 0);

-- Many-to-many: products <-> collections
CREATE TABLE product_collections (
  product_id    UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  collection_id UUID NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
  PRIMARY KEY (product_id, collection_id)
);

-- =========================
-- Cart / Checkout
-- =========================

CREATE TABLE carts (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id  UUID REFERENCES customers(id) ON DELETE SET NULL,
  session_id   VARCHAR,
  status       VARCHAR NOT NULL DEFAULT 'OPEN',   -- enum-like
  created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
ALTER TABLE carts
  ADD CONSTRAINT chk_carts_status_enum
  CHECK (UPPER(status) IN ('OPEN','ORDERED'));
CREATE INDEX idx_carts_customer_id ON carts(customer_id);
CREATE INDEX idx_carts_session_id  ON carts(session_id);

CREATE TABLE cart_items (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cart_id    UUID NOT NULL REFERENCES carts(id) ON DELETE CASCADE,
  variant_id UUID NOT NULL REFERENCES product_variants(id) ON DELETE CASCADE,
  quantity   INTEGER NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
ALTER TABLE cart_items
  ADD CONSTRAINT chk_cart_items_quantity_positive CHECK (quantity > 0);
CREATE UNIQUE INDEX uq_cart_items_cart_variant ON cart_items(cart_id, variant_id);

-- =========================
-- Orders (+ relational address snapshots)
-- =========================

CREATE TABLE orders (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id           UUID REFERENCES customers(id) ON DELETE SET NULL,
  cart_id               UUID UNIQUE REFERENCES carts(id),  -- 1:1 cart↔order (nullable)
  status                VARCHAR NOT NULL,
  currency              VARCHAR NOT NULL DEFAULT 'USD',
  subtotal_price        DECIMAL(10,2) NOT NULL DEFAULT 0,
  total_discounts       DECIMAL(10,2) NOT NULL DEFAULT 0,
  total_tax             DECIMAL(10,2) NOT NULL DEFAULT 0,
  shipping_price        DECIMAL(10,2) NOT NULL DEFAULT 0,
  total_price           DECIMAL(10,2) NOT NULL DEFAULT 0,
  total_weight          DECIMAL(10,3),
  total_weight_unit     VARCHAR NOT NULL DEFAULT 'G',
  notes                 TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
ALTER TABLE orders
  ADD CONSTRAINT chk_orders_total_weight_unit
  CHECK (UPPER(total_weight_unit) IN ('G','KG','LB','OZ'));
ALTER TABLE orders
  ADD CONSTRAINT chk_orders_status_enum
  CHECK (UPPER(status) IN ('PENDING','PROCESSING','ON-HOLD','COMPLETED','CANCELLED','REFUNDED','FAILED','ARCHIVED'));

-- Relational snapshots of order addresses (immutable)
CREATE TABLE order_addresses (
  order_id     UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  type         VARCHAR NOT NULL,  -- 'BILLING' | 'SHIPPING'
  first_name   VARCHAR,
  last_name    VARCHAR,
  company      VARCHAR,
  phone        VARCHAR,
  line1        VARCHAR,
  line2        VARCHAR,
  city         VARCHAR,
  region       VARCHAR,
  postal_code  VARCHAR,
  country_code VARCHAR,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (order_id, type)
);
ALTER TABLE order_addresses
  ADD CONSTRAINT chk_order_addresses_type
  CHECK (UPPER(type) IN ('BILLING','SHIPPING'));

-- Order line items (snapshots)
CREATE TABLE line_items (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id          UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  variant_id        UUID REFERENCES product_variants(id),
  product_id        UUID REFERENCES products(id),
  title             VARCHAR,
  sku               VARCHAR,
  quantity          INTEGER NOT NULL,
  unit_price        DECIMAL(10,2) NOT NULL,
  unit_tax_amount   DECIMAL(10,2) NOT NULL DEFAULT 0,
  total_discount    DECIMAL(10,2) NOT NULL DEFAULT 0,
  total_price       DECIMAL(10,2) NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_line_items_order_id   ON line_items(order_id);
CREATE INDEX idx_line_items_variant_id ON line_items(variant_id);

-- Discounts
CREATE TABLE discounts (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code         VARCHAR UNIQUE,
  application  VARCHAR NOT NULL,   -- 'ORDER' | 'LINE_ITEM' | 'SHIPPING'
  method       VARCHAR NOT NULL,   -- 'PERCENT_OFF' | 'FLAT_RATE'
  value        DECIMAL(10,2) NOT NULL,
  status       VARCHAR NOT NULL,   -- 'ACTIVE' | 'INACTIVE' | 'SCHEDULED' | 'EXPIRED'
  starts_at    TIMESTAMPTZ,
  ends_at      TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
ALTER TABLE discounts ADD CONSTRAINT chk_discounts_application
  CHECK (UPPER(application) IN ('ORDER','LINE_ITEM','SHIPPING'));
ALTER TABLE discounts ADD CONSTRAINT chk_discounts_method
  CHECK (UPPER(method) IN ('PERCENT_OFF','FLAT_RATE'));
ALTER TABLE discounts ADD CONSTRAINT chk_discounts_status
  CHECK (UPPER(status) IN ('ACTIVE','INACTIVE','SCHEDULED','EXPIRED'));

CREATE TABLE order_discount_applications (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  discount_id UUID NOT NULL REFERENCES discounts(id)
);
CREATE INDEX idx_order_discount_applications_order_id ON order_discount_applications(order_id);

CREATE TABLE line_item_discount_allocations (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  line_item_id UUID NOT NULL REFERENCES line_items(id) ON DELETE CASCADE,
  discount_id  UUID NOT NULL REFERENCES discounts(id),
  amount       DECIMAL(10,2) NOT NULL
);
CREATE INDEX idx_lida_line_item_id ON line_item_discount_allocations(line_item_id);

-- =========================
-- Payments (record-keeping)
-- =========================

CREATE TABLE payment_methods (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        VARCHAR NOT NULL,
  provider    VARCHAR,
  details     JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE payment_transactions (
  id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id                        UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  payment_method_id               UUID REFERENCES payment_methods(id),
  amount                          DECIMAL(10,2) NOT NULL,
  currency                        VARCHAR NOT NULL DEFAULT 'USD',
  kind                            VARCHAR NOT NULL,   -- AUTHORIZATION | SALE | CAPTURE | REFUND | VOID
  status                          VARCHAR NOT NULL,   -- PENDING | SUCCESS | FAILURE | ERROR
  payment_method_transaction_id   VARCHAR,           -- idempotency key (gateway txn id)
  raw_payload                     JSONB,
  created_at                      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at                      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
ALTER TABLE payment_transactions
  ADD CONSTRAINT chk_payment_transactions_kind
  CHECK (UPPER(kind) IN ('AUTHORIZATION','SALE','CAPTURE','REFUND','VOID'));
ALTER TABLE payment_transactions
  ADD CONSTRAINT chk_payment_transactions_status
  CHECK (UPPER(status) IN ('PENDING','SUCCESS','FAILURE','ERROR'));
-- Unique when present (idempotency)
CREATE UNIQUE INDEX uq_payment_transactions_gateway_txn
  ON payment_transactions (payment_method_transaction_id)
  WHERE payment_method_transaction_id IS NOT NULL;

-- =========================
-- Fulfillment & Shipping
-- =========================

CREATE TABLE fulfillments (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id         UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  status           VARCHAR NOT NULL,
  shipping_carrier VARCHAR,
  tracking_number  VARCHAR,
  tracking_url     VARCHAR,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
ALTER TABLE fulfillments
  ADD CONSTRAINT chk_fulfillments_status_enum
  CHECK (UPPER(status) IN ('PENDING','PROCESSING','ON-HOLD','COMPLETED','CANCELLED','REFUNDED','FAILED'));
CREATE INDEX idx_fulfillments_order_id ON fulfillments(order_id);

CREATE TABLE fulfillment_line_items (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  fulfillment_id  UUID NOT NULL REFERENCES fulfillments(id) ON DELETE CASCADE,
  line_item_id    UUID NOT NULL REFERENCES line_items(id) ON DELETE CASCADE,
  quantity        INTEGER NOT NULL
);
ALTER TABLE fulfillment_line_items
  ADD CONSTRAINT chk_fulfillment_line_items_quantity_positive CHECK (quantity > 0);

-- =========================
-- Refunds
-- =========================

CREATE TABLE refunds (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  reason      VARCHAR,
  total       DECIMAL(10,2) NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE refund_line_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  refund_id     UUID NOT NULL REFERENCES refunds(id) ON DELETE CASCADE,
  line_item_id  UUID NOT NULL REFERENCES line_items(id),
  quantity      INTEGER NOT NULL,
  amount        DECIMAL(10,2) NOT NULL DEFAULT 0
);
ALTER TABLE refund_line_items
  ADD CONSTRAINT chk_refund_line_items_quantity_positive CHECK (quantity > 0);

-- =========================
-- Reviews (optional MVP)
-- =========================

CREATE TABLE product_reviews (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id   UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  customer_id  UUID REFERENCES customers(id) ON DELETE SET NULL,
  rating       SMALLINT NOT NULL,
  title        VARCHAR,
  body         TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
ALTER TABLE product_reviews
  ADD CONSTRAINT chk_product_reviews_rating_valid CHECK (rating BETWEEN 1 AND 5);

-- ============================================================
-- Triggers & Functions
-- ============================================================

-- Guard: cart_items are immutable unless parent cart is OPEN
CREATE OR REPLACE FUNCTION cart_items_assert_cart_open()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  cart_status VARCHAR;
  target_cart UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN
    target_cart := OLD.cart_id;
  ELSIF TG_OP = 'UPDATE' THEN
    -- If moving to a new cart, verify the destination is OPEN
    IF NEW.cart_id IS DISTINCT FROM OLD.cart_id THEN
      SELECT status INTO cart_status FROM carts WHERE id = NEW.cart_id;
      IF cart_status IS NULL THEN
        RAISE EXCEPTION 'Cart % not found for cart_items %', NEW.cart_id, NEW.id;
      ELSIF UPPER(cart_status) <> 'OPEN' THEN
        RAISE EXCEPTION 'Cannot move items into non-OPEN cart % (status=%)', NEW.cart_id, cart_status
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
    target_cart := OLD.cart_id;
  ELSE -- INSERT
    target_cart := NEW.cart_id;
  END IF;

  IF target_cart IS NOT NULL THEN
    SELECT status INTO cart_status FROM carts WHERE id = target_cart;
    IF cart_status IS NULL THEN
      RAISE EXCEPTION 'Cart % not found for cart_items (%)', target_cart, COALESCE(NEW.id, OLD.id);
    ELSIF UPPER(cart_status) <> 'OPEN' THEN
      RAISE EXCEPTION 'Cart % is %; cart_items are read-only', target_cart, cart_status
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END
$$;

CREATE TRIGGER trg_cart_items_assert_open_ins
BEFORE INSERT ON cart_items
FOR EACH ROW EXECUTE FUNCTION cart_items_assert_cart_open();

CREATE TRIGGER trg_cart_items_assert_open_upd
BEFORE UPDATE ON cart_items
FOR EACH ROW EXECUTE FUNCTION cart_items_assert_cart_open();

CREATE TRIGGER trg_cart_items_assert_open_del
BEFORE DELETE ON cart_items
FOR EACH ROW EXECUTE FUNCTION cart_items_assert_cart_open();

-- Auto-flip cart to ORDERED when an order is created for it
CREATE OR REPLACE FUNCTION orders_flip_cart_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  cur_status VARCHAR;
BEGIN
  IF NEW.cart_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- lock the cart row to avoid races
  SELECT status INTO cur_status FROM carts WHERE id = NEW.cart_id FOR UPDATE;
  IF cur_status IS NULL THEN
    RAISE EXCEPTION 'orders.cart_id % refers to non-existent cart', NEW.cart_id;
  END IF;

  IF UPPER(cur_status) <> 'OPEN' THEN
    RAISE EXCEPTION 'Cart % is not OPEN (status=%); cannot attach to new order', NEW.cart_id, cur_status
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE carts
     SET status = 'ORDERED',
         updated_at = CURRENT_TIMESTAMP
   WHERE id = NEW.cart_id;

  RETURN NEW;
END
$$;

CREATE TRIGGER trg_orders_flip_cart_status
AFTER INSERT ON orders
FOR EACH ROW EXECUTE FUNCTION orders_flip_cart_status();


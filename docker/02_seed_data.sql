-- ============================================================
-- KIRA 플랫폼 통합 시드 데이터 (02_seed_data.sql)
-- ============================================================
-- [버전] 7계층 × 4제품 × 2고객사(BMW/Mercedes) × 12협력사 풀세트
--
-- [regulations 제외]
--   regulations 10종 + pgvector hnsw 인덱스는 01_schema.sql이 적재한다.
--   (regulations: schema가 단일 소스, seed는 시나리오 데이터만)
--
-- [제품 3축] customer_id(고객사) + model_name(차종) + amperage_ah(Ah)
--   bom_versions.production_from/to 로 생산기간 추적.
--
-- [7계층 트리] 0 Pack / 1 Module / 2 Cell / 3 활물질(CAM·ANO)
--             / 4 전구체 / 5 제련·정제 / 6 광산
--
-- [4대 시나리오]
--   ① BMW iX3 (108Ah 원통 NCM811) ── Happy: 한양셀→동성CAM→호주리튬, FEOC 통과 → 발행 완료
--   ② BMW i4  (81Ah 각형)         ── Gray : 대성정밀 전구체 미확인(신뢰도 0.70) → HITL 대기
--   ③ Mercedes GLC EV (94Ah 각형) ── Sad  : Lot1(2024)=청정전구체 정상 / Lot2(2025)=Global Mining 신장 위반·외국지분 25%↑ → 차단
--   ④ Mercedes EQS (118Ah 각형)   ── Happy: 우진배터리→동성CAM→칠레리튬, 정상
--
-- 실행 전제: 01_schema.sql 이후 적재(파일명 알파벳순 자동 실행).
--           파괴적 변경 → 로컬은 docker compose down -v 선행 필수.
-- ============================================================


-- ============================================================
-- 1. 테넌트 / 사용자 / 권한 (영역 1)
-- ============================================================
INSERT INTO tenants (tenant_id, company_name, business_reg_no, subscription_status)
VALUES ('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'KIRA Platform', '123-45-67890', 'active');

-- 원청 관리자 + ESG/구매 담당자 + 협력사 사용자
INSERT INTO users (user_id, tenant_id, email, password_hash, name, role) VALUES
('11111111-0000-4000-8000-000000000001', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'admin@kira.demo',       '$2b$12$XO1O./JYL5VKDkodX2RdpOZSfFA7PSkeViaPqiOSQG4szW7fGVjf.', 'Admin User',      'admin'),
('11111111-0000-4000-8000-000000000002', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'esg@kira.demo',         '$2b$12$XO1O./JYL5VKDkodX2RdpOZSfFA7PSkeViaPqiOSQG4szW7fGVjf.', 'ESG Manager',     'owner_esg'),
('11111111-0000-4000-8000-000000000003', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'buyer@kira.demo',       '$2b$12$XO1O./JYL5VKDkodX2RdpOZSfFA7PSkeViaPqiOSQG4szW7fGVjf.', 'Purchasing Lead', 'owner_purchasing'),
('11111111-0000-4000-8000-000000000004', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'ceo@hanyang.demo',      '$2b$12$XO1O./JYL5VKDkodX2RdpOZSfFA7PSkeViaPqiOSQG4szW7fGVjf.', 'Hanyang CEO',     'supplier_ceo'),
('11111111-0000-4000-8000-000000000005', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'esg@globalmining.demo', '$2b$12$XO1O./JYL5VKDkodX2RdpOZSfFA7PSkeViaPqiOSQG4szW7fGVjf.', 'GMC ESG',         'supplier_esg'),
('11111111-0000-4000-8000-000000000006', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'esg@daesung.demo',      '$2b$12$XO1O./JYL5VKDkodX2RdpOZSfFA7PSkeViaPqiOSQG4szW7fGVjf.', 'Daesung ESG',     'supplier_esg'),
('11111111-0000-4000-8000-000000000007', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'ceo@woojin.demo',       '$2b$12$XO1O./JYL5VKDkodX2RdpOZSfFA7PSkeViaPqiOSQG4szW7fGVjf.', 'Woojin CEO',      'supplier_ceo');

-- 데모 로그인 계정 (프론트 로그인 화면 기본값 — prime/supplier). password: demo1234
-- (구 alembic 0004_demo_accounts 에서 이관 — DDL/데이터 모두 docker schema·seed 로 일원화)
-- 원청(prime) 계정 — 원청은 OEM(고객사)이 아니므로 prime@kira.demo 로 표기.
INSERT INTO users (user_id, tenant_id, email, password_hash, name, role) VALUES
('11111111-0000-4000-8000-0000000000a1', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'prime@kira.demo',            '$2b$12$LdrfIceVZR7twTzU8rxKF.M0uqv9vmcUawZNKRoLjbjb9gAidiynS', 'Demo 원청',         'admin'),
('11111111-0000-4000-8000-0000000000b1', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'supplier@hanyang-cell.com',  '$2b$12$LdrfIceVZR7twTzU8rxKF.M0uqv9vmcUawZNKRoLjbjb9gAidiynS', '한양셀 데모 협력사', 'supplier_ceo');

-- 협력사 계정 ↔ 본인 supplier 매핑 (§0.5 — 로그인 supplier_id 클레임 / 협력사 포털 스코프 소스).
-- 데모 협력사 = 한양셀 제조(주)(a1111111). ceo@hanyang.demo 도 동일 회사로 매핑.
UPDATE users SET supplier_id = 'a1111111-1111-4000-8000-000000000001'
 WHERE email IN ('supplier@hanyang-cell.com', 'ceo@hanyang.demo');


-- ============================================================
-- 2. 고객사 마스터 (영역 7 선행) — OEM 2개
-- ============================================================
INSERT INTO customers (customer_id, customer_code, customer_name, country, source_system, external_id) VALUES
('c0000000-0000-4000-8000-0000000000b1', 'BMW',      'BMW AG',                'DE', 'ERP_PLM', 'ERP-CUST-BMW'),
('c0000000-0000-4000-8000-0000000000b2', 'MERCEDES', 'Mercedes-Benz Group AG','DE', 'ERP_PLM', 'ERP-CUST-MB');


-- ============================================================
-- 4. 협력사 마스터 (영역 2) — 원청 1 + 협력사 12개사
-- ============================================================
-- 원청 (prime, tier0) — 공급망 트리 루트. supply_chain_map 최상위 parent로 사용.
-- 본질은 배터리 팩 '제조사'(provider_type=manufacturer). 원청/협력사 구분은 tier0(hop0)로.
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, company_name_ko, ceo_name, provider_type, completeness_score, status, risk_level) VALUES
('a0000000-0000-4000-8000-000000000000', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'KIRA Energy Solutions', 'KIRA Energy Solutions', '키라에너지솔루션(주)', 'KIRA CEO', 'manufacturer', 100, 'supplier_verified', 'low');

-- 제조사/셀
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, company_name_ko, ceo_name, provider_type, completeness_score, status, risk_level) VALUES
('a1111111-1111-4000-8000-000000000001', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '한양셀 제조(주)', 'Hanyang Cell Mfg',   '한양셀 제조(주)', 'Kim CEO',   'manufacturer', 92, 'supplier_verified',    'low'),
('a7777777-7777-4000-8000-000000000007', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '우진배터리(주)',  'Woojin Battery',     '우진배터리(주)',  'Park CEO',  'manufacturer', 90, 'supplier_verified',    'low'),
('a8888888-8888-4000-8000-000000000008', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '우진셀(주)',      'Woojin Cell',        '우진셀(주)',      'Park CTO',  'manufacturer', 88, 'supplier_verified',    'low');

-- CAM/전구체 (활물질·전구체 tier 4~5)
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, company_name_ko, ceo_name, provider_type, completeness_score, status, risk_level) VALUES
('a2222222-2222-4000-8000-000000000002', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '동성머티리얼(주)', 'Dongsung Material', '동성머티리얼(주)', 'Choi CEO',  'manufacturer', 89, 'supplier_verified',    'low'),
('a4444444-4444-4000-8000-000000000004', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '대성정밀(주)',     'Daesung Precision', '대성정밀(주)',     'Lee CEO',   'manufacturer', 55, 'supplier_review',      'medium'),
('a6666666-6666-4000-8000-000000000006', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '청정전구체(주)',   'Cheongjeong Precursor','청정전구체(주)', 'Jung CEO',  'manufacturer', 85, 'supplier_verified',    'low');

-- 제련·정제 (tier 6)
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, company_name_ko, ceo_name, provider_type, completeness_score, status, risk_level) VALUES
('aaaaaaaa-aaaa-4000-8000-00000000000a', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '한중제련(주)',    'Hanjung Refinery',  '한중제련(주)',    'Yoon CEO',  'smelter', 80, 'supplier_verified',    'low'),
('acacacac-acac-4000-8000-0000000000ac', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Xinjiang Nickel Refinery', 'Xinjiang Nickel Refinery', NULL, 'Wang CEO', 'smelter', 60, 'supplier_review', 'high');

-- 제련소 세부(RMI 기준): 검증완료 = RMAP conformant → rmi / 고위험 신장 = private.
UPDATE suppliers SET smelter_type = 'rmi'     WHERE supplier_id = 'aaaaaaaa-aaaa-4000-8000-00000000000a';
UPDATE suppliers SET smelter_type = 'private' WHERE supplier_id = 'acacacac-acac-4000-8000-0000000000ac';

-- 광산 (tier 7)
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, company_name_ko, ceo_name, provider_type, completeness_score, status, risk_level) VALUES
('a3333333-3333-4000-8000-000000000003', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '호주리튬광업', 'Australia Lithium Mining', NULL, 'Smith CEO', 'miner', 86, 'supplier_verified',  'low'),
('a9999999-9999-4000-8000-000000000009', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '칠레리튬광업', 'Chile Lithium Mining',     NULL, 'Garcia CEO','miner', 84, 'supplier_verified',  'low'),
('a5555555-5555-4000-8000-000000000005', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Global Mining Corp', 'Global Mining Corp', NULL, 'Zhang CEO', 'miner', 35, 'supplier_violation', 'critical');

-- 트레이더 (i4 Gray — 미확인 전구체)
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, provider_type, completeness_score, status, risk_level) VALUES
('abababab-abab-4000-8000-0000000000ab', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Unverified Precursor Trading', 'Unverified Precursor Trading', 'trader', 40, 'supplier_in_progress', 'medium');

-- 소재 국가(ISO 3166-1 alpha-2) 시드 — INSERT에 country 미포함이라 전부 null이던 것 보완(화면 '미입력' 해소).
UPDATE suppliers SET country = CASE supplier_id
  WHEN 'a0000000-0000-4000-8000-000000000000' THEN 'KR'  -- KIRA Energy Solutions(원청)
  WHEN 'a1111111-1111-4000-8000-000000000001' THEN 'KR'  -- 한양셀 제조
  WHEN 'a7777777-7777-4000-8000-000000000007' THEN 'KR'  -- 우진배터리
  WHEN 'a8888888-8888-4000-8000-000000000008' THEN 'KR'  -- 우진셀
  WHEN 'a2222222-2222-4000-8000-000000000002' THEN 'KR'  -- 동성머티리얼
  WHEN 'a4444444-4444-4000-8000-000000000004' THEN 'KR'  -- 대성정밀
  WHEN 'a6666666-6666-4000-8000-000000000006' THEN 'KR'  -- 청정전구체
  WHEN 'aaaaaaaa-aaaa-4000-8000-00000000000a' THEN 'KR'  -- 한중제련
  WHEN 'acacacac-acac-4000-8000-0000000000ac' THEN 'CN'  -- Xinjiang Nickel Refinery
  WHEN 'a3333333-3333-4000-8000-000000000003' THEN 'AU'  -- 호주리튬광업
  WHEN 'a9999999-9999-4000-8000-000000000009' THEN 'CL'  -- 칠레리튬광업
  WHEN 'a5555555-5555-4000-8000-000000000005' THEN 'CN'  -- Global Mining Corp(신장 인접·FEOC 부적격)
  WHEN 'abababab-abab-4000-8000-0000000000ab' THEN 'CN'  -- Unverified Precursor Trading(미확인 원산지)
  ELSE country END;


-- ============================================================
-- 5. 공장 / 사업장 (영역 2) — PostGIS 좌표 (Geo Audit 핵심)
-- ============================================================
-- 신장 좌표 ST_MakePoint(86.0, 41.0) = 신장 폴리곤 내부 (Sad 위반 트리거)
INSERT INTO supplier_factories (factory_id, supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent) VALUES
-- KIRA(원청) 자체 팩 공장 — hop0 엣지 supply_ratio(f0000000) 참조 대상. 03_supply_map_seed 에도 WHERE NOT EXISTS 로 있어 중복 스킵.
('f0000000-0000-4000-8000-000000000000', 'a0000000-0000-4000-8000-000000000000', 'KIRA 수원 팩 생산공장', 'KIRA Suwon Pack Plant', 'KR', 'Suwon', ST_SetSRID(ST_MakePoint(127.009, 37.264), 4326), 'production', 'BOTH', '["EU_BATTERY","EU_BATTERY_ART7","CSDDD"]'::jsonb, 100.00),
-- 한양셀 [Happy] 포항(EU向)
('f1111111-0000-4000-8000-000000000001', 'a1111111-1111-4000-8000-000000000001', '포항 제1공장', 'Pohang Plant 1', 'KR', 'Pohang', ST_SetSRID(ST_MakePoint(129.343, 36.019), 4326), 'production', 'EU', '["EU_BATTERY","EU_BATTERY_ART7","EU_BATTERY_ART47","EUDR","CSDDD"]'::jsonb, 100.00),
-- 우진배터리 [Happy] 울산(EU向)
('f7777777-0000-4000-8000-000000000007', 'a7777777-7777-4000-8000-000000000007', '울산 공장', 'Ulsan Plant', 'KR', 'Ulsan', ST_SetSRID(ST_MakePoint(129.311, 35.538), 4326), 'production', 'EU', '["EU_BATTERY","EU_BATTERY_ART7","CSDDD"]'::jsonb, 100.00),
-- 우진셀
('f8888888-0000-4000-8000-000000000008', 'a8888888-8888-4000-8000-000000000008', '청주 셀공장', 'Cheongju Cell Plant', 'KR', 'Cheongju', ST_SetSRID(ST_MakePoint(127.489, 36.642), 4326), 'production', 'EU', '["EU_BATTERY"]'::jsonb, 100.00),
-- 동성머티리얼 CAM
('f2222222-0000-4000-8000-000000000002', 'a2222222-2222-4000-8000-000000000002', '천안 양극재공장', 'Cheonan CAM Plant', 'KR', 'Cheonan', ST_SetSRID(ST_MakePoint(127.114, 36.815), 4326), 'processing', 'BOTH', '["EU_BATTERY","CRMA","CONFLICT_MINERALS"]'::jsonb, 100.00),
-- 대성정밀 [Gray] 화성
('f4444444-0000-4000-8000-000000000004', 'a4444444-4444-4000-8000-000000000004', '화성 공장', 'Hwaseong Plant', 'KR', 'Hwaseong', ST_SetSRID(ST_MakePoint(126.831, 37.199), 4326), 'processing', 'EU', '["EU_BATTERY","CSDDD"]'::jsonb, 100.00),
-- 청정전구체 [Sad-Lot1 정상]
('f6666666-0000-4000-8000-000000000006', 'a6666666-6666-4000-8000-000000000006', '광양 전구체공장', 'Gwangyang Precursor', 'KR', 'Gwangyang', ST_SetSRID(ST_MakePoint(127.700, 34.940), 4326), 'processing', 'BOTH', '["EU_BATTERY","CRMA"]'::jsonb, 100.00),
-- 한중제련 tier6
('faaaaaaa-0000-4000-8000-00000000000a', 'aaaaaaaa-aaaa-4000-8000-00000000000a', '온산 제련소', 'Onsan Refinery', 'KR', 'Onsan', ST_SetSRID(ST_MakePoint(129.347, 35.428), 4326), 'processing', 'BOTH', '["CRMA"]'::jsonb, 100.00),
-- 신장니켈제련 [Sad tier6]
('facacaca-0000-4000-8000-0000000000ac', 'acacacac-acac-4000-8000-0000000000ac', 'Xinjiang Refinery', 'Xinjiang Refinery', 'CN', 'Xinjiang', ST_SetSRID(ST_MakePoint(86.150, 41.120), 4326), 'processing', 'US', '["UFLPA"]'::jsonb, 100.00),
-- 호주리튬광산 [Happy tier7]
('f3333333-0000-4000-8000-000000000003', 'a3333333-3333-4000-8000-000000000003', 'Greenbushes Mine', 'Greenbushes Mine', 'AU', 'Western Australia', ST_SetSRID(ST_MakePoint(116.060, -33.860), 4326), 'mining', 'BOTH', '["CRMA"]'::jsonb, 100.00),
-- 칠레리튬광산 [Happy tier7]
('f9999999-0000-4000-8000-000000000009', 'a9999999-9999-4000-8000-000000000009', 'Atacama Mine', 'Atacama Mine', 'CL', 'Antofagasta', ST_SetSRID(ST_MakePoint(-68.200, -23.500), 4326), 'mining', 'BOTH', '["CRMA"]'::jsonb, 100.00),
-- Global Mining 신장 광산 [Sad tier7 — 위반 핵심 노드]
('f5555555-0000-4000-8000-000000000005', 'a5555555-5555-4000-8000-000000000005', 'Xinjiang NCM Mine A', 'Xinjiang NCM Mine A', 'CN', 'Xinjiang', ST_SetSRID(ST_MakePoint(86.000, 41.000), 4326), 'mining', 'US', '["UFLPA"]'::jsonb, 100.00);

-- 연락 담당자 (주요 3사)
INSERT INTO supplier_contacts (supplier_id, factory_id, name, name_en, role, department, email, phone, is_primary, language) VALUES
('a1111111-1111-4000-8000-000000000001', 'f1111111-0000-4000-8000-000000000001', '김담당', 'Mr. Kim', 'ESG Manager', 'Sustainability', 'kim@hanyang.demo', '+82-54-000-0001', TRUE, 'ko'),
('a5555555-5555-4000-8000-000000000005', 'f5555555-0000-4000-8000-000000000005', 'Li Manager', 'Li Manager', 'Compliance', 'Compliance', 'li@globalmining.demo', '+86-991-000-0005', TRUE, 'en'),
('a4444444-4444-4000-8000-000000000004', 'f4444444-0000-4000-8000-000000000004', '이담당', 'Ms. Lee', 'Quality', 'QA', 'lee@daesung.demo', '+82-31-000-0004', TRUE, 'ko');

-- 온보딩 / SLA
INSERT INTO supplier_onboarding (supplier_id, consent_status, consent_signed_at, agreement_status, last_invited_at, sla_due_date, reminder_count) VALUES
('a1111111-1111-4000-8000-000000000001', 'consent_agreed',  now() - interval '20 days', 'agreed',  now() - interval '21 days', now() - interval '7 days', 0),
('a4444444-4444-4000-8000-000000000004', 'consent_agreed',  now() - interval '5 days',  'agreed',  now() - interval '6 days',  now() + interval '8 days', 1),
('abababab-abab-4000-8000-0000000000ab', 'consent_pending', NULL,                        'pending', now() - interval '22 days', now() - interval '8 days', 3);


-- ============================================================
-- 3. 제품 마스터 4종 + BOM 버전 (영역 7) — 3축(고객사·기간·조성)
-- ============================================================
-- ① BMW iX3 50 — 108Ah 원통형 NCM811 [Happy]
-- ② BMW i4     — 81Ah 각형 NCM       [Gray]
-- ③ Mercedes GLC EV — 94Ah 각형 NCM  [Sad, 기간별 2 Lot]
-- ④ Mercedes EQS    — 118Ah 각형 NCM [Happy]
-- [순서 이동 이유] products.manufacturer_id → suppliers FK 의존.
--   suppliers 마스터(4번)와 공장(5번)이 모두 INSERT된 뒤에 와야 FK 위반이 안 난다.
INSERT INTO products (product_id, product_code, product_name, manufacturer_id, tenant_id, customer_id, model_name, amperage_ah, type, source_system, external_id) VALUES
-- manufacturer_id = KIRA(원청·팩 제조사). 우리가 만드는 팩이므로 제조사는 KIRA. (이전 시드: 한양셀/우진배터리로 잘못 지정)
-- product_name/code: 실제 셀 제조사 관례대로 자사 브랜드(KIRA PRiMX)+사양(폼팩터·화학조성·용량). OEM 차종은 제품명에 박지 않고
-- customer_id(고객사)와 model_name(납품 차종)으로 분리 — (제품 × 고객사 × 단위기간) 그룹핑·검색·맵핑을 위해.
('d1111111-0000-4000-8000-000000000001', 'KE-CYL-NCM811-108', 'KIRA PRiMX Cylindrical NCM811 108Ah', 'a0000000-0000-4000-8000-000000000000', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'c0000000-0000-4000-8000-0000000000b1', 'iX3 50',  108.00, 'battery_pack', 'ERP_PLM', 'ERP-PROD-IX3'),
('d2222222-0000-4000-8000-000000000002', 'KE-PRI-NCM-081',    'KIRA PRiMX Prismatic NCM 81Ah',       'a0000000-0000-4000-8000-000000000000', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'c0000000-0000-4000-8000-0000000000b1', 'i4',       81.00, 'battery_pack', 'ERP_PLM', 'ERP-PROD-I4'),
('d3333333-0000-4000-8000-000000000003', 'KE-PRI-NCM-094',    'KIRA PRiMX Prismatic NCM 94Ah',       'a0000000-0000-4000-8000-000000000000', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'c0000000-0000-4000-8000-0000000000b2', 'GLC EV',   94.00, 'battery_pack', 'ERP_PLM', 'ERP-PROD-GLC'),
('d4444444-0000-4000-8000-000000000004', 'KE-PRI-NCM-118',    'KIRA PRiMX Prismatic NCM 118Ah',      'a0000000-0000-4000-8000-000000000000', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'c0000000-0000-4000-8000-0000000000b2', 'EQS',     118.00, 'battery_pack', 'ERP_PLM', 'ERP-PROD-EQS');

-- BOM 버전: ③ GLC만 기간별 2 Lot(2024 정상 / 2025 신장 위반), 나머지 단일
INSERT INTO bom_versions (bom_version_id, product_id, version_number, production_from, production_to, status, source_system, external_id) VALUES
('e1111111-0000-4000-8000-000000000001', 'd1111111-0000-4000-8000-000000000001', '1.0', '2025-01-01', NULL,         'active',     'ERP_PLM', 'ERP-BOM-IX3'),
('e2222222-0000-4000-8000-000000000002', 'd2222222-0000-4000-8000-000000000002', '1.0', '2025-01-01', NULL,         'active',     'ERP_PLM', 'ERP-BOM-I4'),
('e3333333-0000-4000-8000-000000000031', 'd3333333-0000-4000-8000-000000000003', '1.0', '2024-01-01', '2024-12-31', 'deprecated', 'ERP_PLM', 'ERP-BOM-GLC-2024'),
('e3333333-0000-4000-8000-000000000032', 'd3333333-0000-4000-8000-000000000003', '2.0', '2025-01-01', NULL,         'active',     'ERP_PLM', 'ERP-BOM-GLC-2025'),
('e4444444-0000-4000-8000-000000000004', 'd4444444-0000-4000-8000-000000000004', '1.0', '2025-01-01', NULL,         'active',     'ERP_PLM', 'ERP-BOM-EQS');


-- ============================================================
-- 6. Provider Type CTI 상세 (영역 3)
-- ============================================================
-- 제조 탄소집약도 (EU 배터리법 Art.7)
INSERT INTO supplier_manufacturer_details (supplier_id, manufacturing_process, energy_source, capacity, carbon_intensity) VALUES
('a1111111-1111-4000-8000-000000000001', 'NCM811 Cell Assembly', 'renewable', '10GWh/yr', 2.3400),
('a7777777-7777-4000-8000-000000000007', 'Prismatic NCM Cell Assembly', 'renewable', '8GWh/yr', 2.5100),
('a2222222-2222-4000-8000-000000000002', 'CAM Sintering (NCM811)', 'mixed', '5GWh/yr', 3.1000),
-- 대성정밀: energy_source NULL (저신뢰 파싱 원인 — Gray)
('a4444444-4444-4000-8000-000000000004', 'NCM 양극재/활물질 가공', NULL, '2GWh/yr', NULL);

-- 신장 광산 상세 (Sad — Ni/Co/Mn/Li 원광) + 신장 좌표
INSERT INTO supplier_miner_details (supplier_id, mine_name, mining_method, extraction_volume, mine_coordinates, active_period_from) VALUES
('a5555555-5555-4000-8000-000000000005', 'Xinjiang NCM Mineral Mine A', 'open_pit', 50000.00, ST_SetSRID(ST_MakePoint(86.000, 41.000), 4326), '2020-01-01'),
('a3333333-3333-4000-8000-000000000003', 'Greenbushes Lithium', 'open_pit', 80000.00, ST_SetSRID(ST_MakePoint(116.060, -33.860), 4326), '2018-01-01'),
('a9999999-9999-4000-8000-000000000009', 'Atacama Brine', 'brine', 60000.00, ST_SetSRID(ST_MakePoint(-68.200, -23.500), 4326), '2019-01-01');


-- ============================================================
-- 7. 리스크 프로필 (영역 4)
-- ============================================================
INSERT INTO supplier_risk_profiles (supplier_id, overall_risk_score, risk_level, self_reported_risk_level, is_high_risk_flag, high_risk_reasons, last_risk_review_at) VALUES
-- 원청 (tier0 루트) — 트리 루트 노드 색상/리스크 NULL 방지용 최소 프로필
('a0000000-0000-4000-8000-000000000000', 0,  'low',      'low',     FALSE, NULL, now() - interval '7 days'),
('a1111111-1111-4000-8000-000000000001', 10, 'low',      'low',     FALSE, NULL, now() - interval '7 days'),
('a7777777-7777-4000-8000-000000000007', 10, 'low',      'low',     FALSE, NULL, now() - interval '7 days'),
('a2222222-2222-4000-8000-000000000002', 15, 'low',      'low',     FALSE, NULL, now() - interval '7 days'),
-- Global Mining: critical (신장 인접 광산 / UFLPA)
('a5555555-5555-4000-8000-000000000005', 80, 'critical', 'medium',  TRUE,  '["신장 인접 광산","UFLPA 강제노동 의혹"]'::jsonb, now() - interval '2 days'),
('acacacac-acac-4000-8000-0000000000ac', 55, 'high',     'low',     TRUE,  '["신장 인접 제련소"]'::jsonb, now() - interval '4 days'),
-- 대성정밀: medium (자료 미비)
('a4444444-4444-4000-8000-000000000004', 35, 'medium',   'low',     FALSE, '["자료 완성도 미흡"]'::jsonb, now() - interval '3 days'),
('abababab-abab-4000-8000-0000000000ab', 30, 'medium',   'unknown', FALSE, '["공개율 45%"]'::jsonb, now() - interval '10 days');

-- 실사 기록 (Global Mining 보완 필요)
INSERT INTO supplier_audit_records (supplier_id, audit_date, audit_type, auditor, audit_status, inspector_id, result, next_audit_due) VALUES
('a5555555-5555-4000-8000-000000000005', now()::date - 30, 'on_site', 'Third Party Auditor', 'in_progress', '11111111-0000-4000-8000-000000000002', 'pending', now()::date + 30);


-- ============================================================
-- 10. 부품 7계층 트리 (영역 7) — NCM811 공유 마스터
-- ============================================================
-- T0 Pack → T1 Module → T2 Cell → T3 활물질(CAM·ANO)
--   → T4 전구체(PRE)·정제리튬(LiOH) → T5 제련(Ni·Co·Mn) → T6 광산 원광(Ni·Co·Mn·Li)
INSERT INTO parts (part_id, part_code, part_name, tier_level, parent_part_id, hs_code, material_type, unit_price, source_system, external_id) VALUES
-- T1
('b1111111-0000-4000-8000-000000000001', 'PACK-NCM811',  'Battery Pack',            0, NULL,                                     '850760', 'assembly',        1000.0000, 'ERP_PLM', 'ERP-PART-PACK'),
-- T2
('b1111111-0000-4000-8000-000000000002', 'MOD-NCM811',   'Module',                  1, 'b1111111-0000-4000-8000-000000000001', '850760', 'assembly',         400.0000, 'ERP_PLM', 'ERP-PART-MOD'),
-- T3
('b1111111-0000-4000-8000-000000000003', 'CELL-NCM811',  'Battery Cell',            2, 'b1111111-0000-4000-8000-000000000002', '850760', 'cell',             150.0000, 'ERP_PLM', 'ERP-PART-CELL'),
-- T4 활물질
('b1111111-0000-4000-8000-000000000006', 'CAM-NCM811',   'Cathode Active Material', 3, 'b1111111-0000-4000-8000-000000000003', '284190', 'active_material',    90.0000, 'ERP_PLM', 'ERP-PART-CAM'),
('b1111111-0000-4000-8000-000000000007', 'ANO-GRAPHITE', 'Anode Active Material',   3, 'b1111111-0000-4000-8000-000000000003', '380110', 'active_material',    30.0000, 'ERP_PLM', 'ERP-PART-ANO'),
-- T5 전구체·정제리튬
('b1111111-0000-4000-8000-000000000004', 'PRE-NCM',      'NCM Precursor',           4, 'b1111111-0000-4000-8000-000000000006', '382490', 'precursor',          40.0000, 'ERP_PLM', 'ERP-PART-PRE'),
('b1111111-0000-4000-8000-000000000005', 'LIOH-REFINED', 'Lithium Hydroxide',       4, 'b1111111-0000-4000-8000-000000000006', '282520', 'refined_metal',      84.0000, 'ERP_PLM', 'ERP-PART-LIOH'),
-- T6 제련 (전구체의 상위 = Ni·Co·Mn 황산염/정제금속)
('b1111111-0000-4000-8000-000000000011', 'REF-NI',       'Refined Nickel Sulfate',  5, 'b1111111-0000-4000-8000-000000000004', '283324', 'refined_metal',      22.0000, 'ERP_PLM', 'ERP-PART-REFNI'),
('b1111111-0000-4000-8000-000000000012', 'REF-CO',       'Refined Cobalt Sulfate',  5, 'b1111111-0000-4000-8000-000000000004', '283329', 'refined_metal',      36.0000, 'ERP_PLM', 'ERP-PART-REFCO'),
('b1111111-0000-4000-8000-000000000013', 'REF-MN',       'Refined Manganese Sulfate',5,'b1111111-0000-4000-8000-000000000004', '283339', 'refined_metal',       6.0000, 'ERP_PLM', 'ERP-PART-REFMN'),
-- T7 광산 원광 (제련의 상위)
('b1111111-0000-4000-8000-000000000008', 'MIN-NI',       'Nickel Ore',              6, 'b1111111-0000-4000-8000-000000000011', '260400', 'mineral',            18.0000, 'ERP_PLM', 'ERP-PART-NI'),
('b1111111-0000-4000-8000-000000000009', 'MIN-CO',       'Cobalt Ore',              6, 'b1111111-0000-4000-8000-000000000012', '260500', 'mineral',            32.0000, 'ERP_PLM', 'ERP-PART-CO'),
('b1111111-0000-4000-8000-00000000000a', 'MIN-MN',       'Manganese Ore',           6, 'b1111111-0000-4000-8000-000000000013', '260200', 'mineral',             4.0000, 'ERP_PLM', 'ERP-PART-MN'),
('b1111111-0000-4000-8000-00000000000b', 'MIN-LI',       'Lithium Ore (Spodumene)', 6, 'b1111111-0000-4000-8000-000000000005', '253090', 'mineral',            12.0000, 'ERP_PLM', 'ERP-PART-LI');

-- 부품 용도/기능(parts.function_purpose) 시드 — INSERT에 미포함이라 전부 null이던 것 보완(BOM 트리 표시용).
UPDATE parts SET function_purpose = CASE part_code
  WHEN 'PACK-NCM811'  THEN 'EV 구동용 배터리 팩 — 셀·모듈 통합 및 BMS 제어'
  WHEN 'MOD-NCM811'   THEN '셀 직병렬 묶음 모듈 — 전압 구성·열 관리'
  WHEN 'CELL-NCM811'  THEN '전기 저장·방출 단위 셀(NCM811)'
  WHEN 'ANO-GRAPHITE' THEN '음극 활물질 — 리튬이온 흡장·방출(흑연)'
  WHEN 'CAM-NCM811'   THEN '양극 활물질 — 에너지밀도 결정(NCM811)'
  WHEN 'LIOH-REFINED' THEN '양극재 합성용 리튬 원료(수산화리튬)'
  WHEN 'PRE-NCM'      THEN '양극 활물질 전구체(Ni·Co·Mn 수산화물)'
  WHEN 'REF-CO'       THEN '전구체용 정제 코발트(황산코발트)'
  WHEN 'REF-MN'       THEN '전구체용 정제 망간(황산망간)'
  WHEN 'REF-NI'       THEN '전구체용 정제 니켈(황산니켈)'
  WHEN 'MIN-CO'       THEN '코발트 원광 — 정제 전 원자재'
  WHEN 'MIN-LI'       THEN '리튬 원광(스포듀민) — 수산화리튬 원자재'
  WHEN 'MIN-MN'       THEN '망간 원광 — 정제 전 원자재'
  WHEN 'MIN-NI'       THEN '니켈 원광 — 정제 전 원자재'
  ELSE function_purpose END;

-- ------------------------------------------------------------
-- bom_items: 5개 BOM 버전에 동일 부품 트리 연결 (조성비 NCM811: Ni80/Co10/Mn10)
--   GLC는 Lot1(2024)/Lot2(2025) 2버전 — 동일 부품, 공급사만 supply_chain_map에서 분기
-- ------------------------------------------------------------
-- 매크로적으로 각 bom_version_id별 7계층 전 품목 반복.
-- ① BMW iX3 (e1)
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, direct_material_cost, origin_country, source_system, external_id) VALUES
('e1111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000003', 100, 'ea', 60.00, 150.0000, 'KR', 'ERP_PLM', 'ERP-BI-IX3-CELL'),
('e1111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000006', 40,  'kg', 18.00,  90.0000, 'KR', 'ERP_PLM', 'ERP-BI-IX3-CAM'),
('e1111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000007', 35,  'kg', 12.00,  30.0000, 'KR', 'ERP_PLM', 'ERP-BI-IX3-ANO'),
('e1111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000011', 24,  'kg',  8.00,  22.0000, 'KR', 'ERP_PLM', 'ERP-BI-IX3-REFNI'),
('e1111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000008', 30,  'kg',  4.00,  18.0000, 'AU', 'ERP_PLM', 'ERP-BI-IX3-NI'),
('e1111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-00000000000b', 12,  'kg',  2.00,  12.0000, 'AU', 'ERP_PLM', 'ERP-BI-IX3-LI');

-- ② BMW i4 (e2) — Gray: 전구체 미확인
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, direct_material_cost, origin_country, source_system, external_id) VALUES
('e2222222-0000-4000-8000-000000000002', 'b1111111-0000-4000-8000-000000000003', 90,  'ea', 60.00, 150.0000, 'KR', 'ERP_PLM', 'ERP-BI-I4-CELL'),
('e2222222-0000-4000-8000-000000000002', 'b1111111-0000-4000-8000-000000000006', 38,  'kg', 18.00,  90.0000, 'KR', 'ERP_PLM', 'ERP-BI-I4-CAM'),
('e2222222-0000-4000-8000-000000000002', 'b1111111-0000-4000-8000-000000000004', 20,  'kg', 10.00,  40.0000, NULL, 'ERP_PLM', 'ERP-BI-I4-PRE');

-- ③ Mercedes GLC Lot1 2024 (e31) — 정상: 청정전구체
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, direct_material_cost, origin_country, source_system, external_id) VALUES
('e3333333-0000-4000-8000-000000000031', 'b1111111-0000-4000-8000-000000000003', 95,  'ea', 60.00, 150.0000, 'KR', 'ERP_PLM', 'ERP-BI-GLC1-CELL'),
('e3333333-0000-4000-8000-000000000031', 'b1111111-0000-4000-8000-000000000004', 22,  'kg', 12.00,  40.0000, 'KR', 'ERP_PLM', 'ERP-BI-GLC1-PRE');

-- ③ Mercedes GLC Lot2 2025 (e32) — Sad: Global Mining 신장 전구체
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, direct_material_cost, origin_country, source_system, external_id) VALUES
('e3333333-0000-4000-8000-000000000032', 'b1111111-0000-4000-8000-000000000003', 95,  'ea', 60.00, 150.0000, 'KR', 'ERP_PLM', 'ERP-BI-GLC2-CELL'),
('e3333333-0000-4000-8000-000000000032', 'b1111111-0000-4000-8000-000000000004', 22,  'kg', 12.00,  40.0000, 'CN', 'ERP_PLM', 'ERP-BI-GLC2-PRE'),
('e3333333-0000-4000-8000-000000000032', 'b1111111-0000-4000-8000-000000000008', 30,  'kg',  4.00,  18.0000, 'CN', 'ERP_PLM', 'ERP-BI-GLC2-NI');

-- ④ Mercedes EQS (e4) — Happy: 칠레리튬
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, direct_material_cost, origin_country, source_system, external_id) VALUES
('e4444444-0000-4000-8000-000000000004', 'b1111111-0000-4000-8000-000000000003', 110, 'ea', 60.00, 150.0000, 'KR', 'ERP_PLM', 'ERP-BI-EQS-CELL'),
('e4444444-0000-4000-8000-000000000004', 'b1111111-0000-4000-8000-000000000006', 45,  'kg', 18.00,  90.0000, 'KR', 'ERP_PLM', 'ERP-BI-EQS-CAM'),
('e4444444-0000-4000-8000-000000000004', 'b1111111-0000-4000-8000-00000000000b', 14,  'kg',  2.00,  12.0000, 'CL', 'ERP_PLM', 'ERP-BI-EQS-LI');

-- ============================================================
-- 11. 공급망 맵 (영역 8) — 원청 루트 + hop 경로순번 연속 연결
-- ============================================================
-- [차수 SSOT] hop_level = 원청(parent NULL)=0 기준 경로 순번(+1 연속, 건너뛰기 금지).
--   · 트리 루트 = 원청 KIRA Energy Solutions(a0..0) 가 Pack(hop0) 을 만든다.
--   · 부품 tier(bom_depth=parts.tier_level)와는 독립축 → 같은 hop 이라도 tier 는 다를 수 있고,
--     겸업/계층건너뜀 시 hop != tier 가 정상.
--   · 겸업(다중역할) 공급사는 같은 supplier_id 가 연속 hop 에 self-edge(parent=child)로 중복 등장.
--     예) 한양셀 = Module(hop1) + Cell(hop2).
-- ------------------------------------------------------------
-- ① BMW iX3 [Happy] 원청→한양셀(Module→Cell 겸업)→동성CAM→한중제련→호주리튬
INSERT INTO supply_chain_map (edge_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('51111111-0000-4000-8000-000000000001', 'e1111111-0000-4000-8000-000000000001', NULL,                                     'a0000000-0000-4000-8000-000000000000', 'b1111111-0000-4000-8000-000000000001', 0, 'supplychain_confirmed', 'ERP', 'verified', '2025-01-01', '2025-12-31'),
('51111111-0000-4000-8000-000000000002', 'e1111111-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000000', 'a1111111-1111-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000002', 1, 'supplychain_confirmed', 'ERP', 'verified', '2025-01-01', '2025-12-31'),
('51111111-0000-4000-8000-000000000003', 'e1111111-0000-4000-8000-000000000001', 'a1111111-1111-4000-8000-000000000001', 'a1111111-1111-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000003', 2, 'supplychain_confirmed', 'ERP', 'verified', '2025-01-01', '2025-12-31'),
('51111111-0000-4000-8000-000000000004', 'e1111111-0000-4000-8000-000000000001', 'a1111111-1111-4000-8000-000000000001', 'a2222222-2222-4000-8000-000000000002', 'b1111111-0000-4000-8000-000000000006', 3, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
('51111111-0000-4000-8000-000000000005', 'e1111111-0000-4000-8000-000000000001', 'a2222222-2222-4000-8000-000000000002', 'aaaaaaaa-aaaa-4000-8000-00000000000a', 'b1111111-0000-4000-8000-000000000011', 4, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
('51111111-0000-4000-8000-000000000006', 'e1111111-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4000-8000-00000000000a', 'a3333333-3333-4000-8000-000000000003', 'b1111111-0000-4000-8000-000000000008', 5, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31');

-- ② BMW i4 [Gray] 원청→한양셀(Module→Cell 겸업)→동성CAM→미확인트레이더(전구체, 선언만)
INSERT INTO supply_chain_map (edge_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('52222222-0000-4000-8000-000000000001', 'e2222222-0000-4000-8000-000000000002', NULL,                                     'a0000000-0000-4000-8000-000000000000', 'b1111111-0000-4000-8000-000000000001', 0, 'supplychain_confirmed', 'ERP', 'verified', '2025-01-01', '2025-12-31'),
('52222222-0000-4000-8000-000000000002', 'e2222222-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000000', 'a1111111-1111-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000002', 1, 'supplychain_confirmed', 'ERP', 'verified', '2025-01-01', '2025-12-31'),
('52222222-0000-4000-8000-000000000003', 'e2222222-0000-4000-8000-000000000002', 'a1111111-1111-4000-8000-000000000001', 'a1111111-1111-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000003', 2, 'supplychain_confirmed', 'ERP', 'verified', '2025-01-01', '2025-12-31'),
('52222222-0000-4000-8000-000000000004', 'e2222222-0000-4000-8000-000000000002', 'a1111111-1111-4000-8000-000000000001', 'a2222222-2222-4000-8000-000000000002', 'b1111111-0000-4000-8000-000000000006', 3, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
('52222222-0000-4000-8000-000000000005', 'e2222222-0000-4000-8000-000000000002', 'a2222222-2222-4000-8000-000000000002', 'abababab-abab-4000-8000-0000000000ab', 'b1111111-0000-4000-8000-000000000004', 4, 'supplychain_declared',  'SUPPLIER_DECLARED', 'unverified', '2025-01-01', '2025-12-31');

-- ③ Mercedes GLC Lot1 2024 [Sad-정상] 원청→우진셀→청정전구체 (CAM 계층 건너뜀: hop 연속, tier 점프)
INSERT INTO supply_chain_map (edge_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('53111111-0000-4000-8000-000000000001', 'e3333333-0000-4000-8000-000000000031', NULL,                                     'a0000000-0000-4000-8000-000000000000', 'b1111111-0000-4000-8000-000000000001', 0, 'supplychain_confirmed', 'ERP', 'verified', '2024-01-01', '2024-12-31'),
('53111111-0000-4000-8000-000000000002', 'e3333333-0000-4000-8000-000000000031', 'a0000000-0000-4000-8000-000000000000', 'a8888888-8888-4000-8000-000000000008', 'b1111111-0000-4000-8000-000000000003', 1, 'supplychain_confirmed', 'ERP', 'verified', '2024-01-01', '2024-12-31'),
('53111111-0000-4000-8000-000000000003', 'e3333333-0000-4000-8000-000000000031', 'a8888888-8888-4000-8000-000000000008', 'a6666666-6666-4000-8000-000000000006', 'b1111111-0000-4000-8000-000000000004', 2, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2024-01-01', '2024-12-31');

-- ③ Mercedes GLC Lot2 2025 [Sad-위반] 원청→우진셀→신장니켈제련(전구체)→Global Mining(신장 니켈광산)
INSERT INTO supply_chain_map (edge_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('53222222-0000-4000-8000-000000000001', 'e3333333-0000-4000-8000-000000000032', NULL,                                     'a0000000-0000-4000-8000-000000000000', 'b1111111-0000-4000-8000-000000000001', 0, 'supplychain_confirmed', 'ERP', 'verified', '2025-01-01', '2025-12-31'),
('53222222-0000-4000-8000-000000000002', 'e3333333-0000-4000-8000-000000000032', 'a0000000-0000-4000-8000-000000000000', 'a8888888-8888-4000-8000-000000000008', 'b1111111-0000-4000-8000-000000000003', 1, 'supplychain_confirmed', 'ERP', 'verified', '2025-01-01', '2025-12-31'),
('53222222-0000-4000-8000-000000000003', 'e3333333-0000-4000-8000-000000000032', 'a8888888-8888-4000-8000-000000000008', 'acacacac-acac-4000-8000-0000000000ac', 'b1111111-0000-4000-8000-000000000004', 2, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
('53222222-0000-4000-8000-000000000004', 'e3333333-0000-4000-8000-000000000032', 'acacacac-acac-4000-8000-0000000000ac', 'a5555555-5555-4000-8000-000000000005', 'b1111111-0000-4000-8000-000000000008', 3, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31');

-- ④ Mercedes EQS [Happy] 원청→우진배터리→동성CAM→칠레리튬
INSERT INTO supply_chain_map (edge_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('54444444-0000-4000-8000-000000000001', 'e4444444-0000-4000-8000-000000000004', NULL,                                     'a0000000-0000-4000-8000-000000000000', 'b1111111-0000-4000-8000-000000000001', 0, 'supplychain_confirmed', 'ERP', 'verified', '2025-01-01', '2025-12-31'),
('54444444-0000-4000-8000-000000000002', 'e4444444-0000-4000-8000-000000000004', 'a0000000-0000-4000-8000-000000000000', 'a7777777-7777-4000-8000-000000000007', 'b1111111-0000-4000-8000-000000000003', 1, 'supplychain_confirmed', 'ERP', 'verified', '2025-01-01', '2025-12-31'),
('54444444-0000-4000-8000-000000000003', 'e4444444-0000-4000-8000-000000000004', 'a7777777-7777-4000-8000-000000000007', 'a2222222-2222-4000-8000-000000000002', 'b1111111-0000-4000-8000-000000000006', 2, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
('54444444-0000-4000-8000-000000000004', 'e4444444-0000-4000-8000-000000000004', 'a2222222-2222-4000-8000-000000000002', 'aaaaaaaa-aaaa-4000-8000-00000000000a', 'b1111111-0000-4000-8000-000000000005', 3, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
-- hop4: 한중제련(smelter)→칠레리튬(광산). 광산은 무조건 상위 제련소(smelter)와 엮여야 함(정보관리 주체=smelter).
('54444444-0000-4000-8000-000000000005', 'e4444444-0000-4000-8000-000000000004', 'aaaaaaaa-aaaa-4000-8000-00000000000a', 'a9999999-9999-4000-8000-000000000009', 'b1111111-0000-4000-8000-00000000000b', 4, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31');

-- 공급망 맵 헤더(supply_chain_maps): bom_version(제품 BOM 버전)당 1개. 엣지의 map_id(헤더 FK) 백필.
INSERT INTO supply_chain_maps (map_id, bom_version_id, product_id, status)
SELECT gen_random_uuid(), bv.bom_version_id, bv.product_id, 'completed'
FROM bom_versions bv
WHERE EXISTS (SELECT 1 FROM supply_chain_map scm WHERE scm.bom_version_id = bv.bom_version_id);
UPDATE supply_chain_map scm SET map_id = h.map_id
FROM supply_chain_maps h WHERE h.bom_version_id = scm.bom_version_id;

-- 분할 납품 비율 (iX3 1차 납품: 한양셀→원청, hop1 — 한양 단일공장 100%)
--   최상위 납품 조인이 hop_level=1 엣지의 supply_ratio.volume 을 사용 → hop1(edge ...002)에 연결.
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit) VALUES
('51111111-0000-4000-8000-000000000002', 'f1111111-0000-4000-8000-000000000001', 100.00, 10000, 'ea');

-- ============================================================
-- 11-A. 공급망 맵 엣지 정정 + 제품별 핵심광물 (supply_chain_map.core_minerals override)
-- ============================================================
-- [설계] core_minerals 는 회사(suppliers)당 1값이 기본(fallback). 같은 회사라도 제품(BOM)마다
--   산출물이 다를 수 있어 엣지(supply_chain_map)에 per-product override 를 둔다.
--   조회 시 COALESCE(엣지값, child 회사값) → 엣지값을 비우면 회사값으로 폴백(드리프트 없음).
--   여기서 채우는 건 (1) 회사값이 NULL인 최상위 노드, (2) 같은 회사가 제품별로 달라야 하는 노드뿐.

-- (1) part_id 정정 — iX3 말단이 리튬광(호주리튬)인데 니켈 부품(REF-NI/MIN-NI)에 붙어 있던 불일치 수정.
--   EQS 정상 리튬체인(한중제련 LIOH → 칠레리튬 MIN-LI)과 동일 패턴으로 정합.
UPDATE supply_chain_map SET part_id = 'b1111111-0000-4000-8000-000000000005'  -- REF-NI → LIOH-REFINED
  WHERE edge_id = '51111111-0000-4000-8000-000000000005';
UPDATE supply_chain_map SET part_id = 'b1111111-0000-4000-8000-00000000000b'  -- MIN-NI → MIN-LI
  WHERE edge_id = '51111111-0000-4000-8000-000000000006';

-- (2) 엣지 전면 표준화 — core_minerals = 그 엣지에 흐르는 부품(part_id)의 핵심광물 원소 질량%(EU DPP 기준).
--   순도(99%)/비율(Ni80) 혼용을 제거하고 '원소 함량'으로 통일. 회사값(suppliers)·마스터폼은 그대로 두고
--   엣지만 override → 폼 드리프트 0. 같은 회사도 제품마다 다른 부품을 대면 값이 갈린다(예: 한중제련 LIOH).
--   위반/Gray 서사 노드(Global Mining·Unverified Trader)는 데이터 결손이 서사이므로 NULL 유지(override 안 함).

--  · NCM811 양극활물질 조성(PACK/Module/Cell/CAM 공통): Li7.1/Ni48.3/Co6.1/Mn5.6
--    (팩/셀/모듈은 양극활물질 조성 기준으로 표기 — 팩 전체 질량 희석은 양극재 질량비가 데이터에 없어 이 데모 범위 밖)
UPDATE supply_chain_map SET core_minerals = '{"Li":7.1,"Ni":48.3,"Co":6.1,"Mn":5.6}'::jsonb
  WHERE edge_id IN (
    '51111111-0000-4000-8000-000000000001',  -- iX3  hop0 KIRA     PACK
    '51111111-0000-4000-8000-000000000002',  -- iX3  hop1 한양셀    Module
    '51111111-0000-4000-8000-000000000003',  -- iX3  hop2 한양셀    Cell
    '51111111-0000-4000-8000-000000000004',  -- iX3  hop3 동성      CAM
    '52222222-0000-4000-8000-000000000001',  -- i4   hop0 KIRA     PACK
    '52222222-0000-4000-8000-000000000002',  -- i4   hop1 한양셀    Module
    '52222222-0000-4000-8000-000000000003',  -- i4   hop2 한양셀    Cell
    '52222222-0000-4000-8000-000000000004',  -- i4   hop3 동성      CAM
    '53111111-0000-4000-8000-000000000001',  -- GLC1 hop0 KIRA     PACK
    '53111111-0000-4000-8000-000000000002',  -- GLC1 hop1 우진셀    Cell
    '53222222-0000-4000-8000-000000000001',  -- GLC2 hop0 KIRA     PACK
    '53222222-0000-4000-8000-000000000002',  -- GLC2 hop1 우진셀    Cell
    '54444444-0000-4000-8000-000000000001',  -- EQS  hop0 KIRA     PACK
    '54444444-0000-4000-8000-000000000002',  -- EQS  hop1 우진배터리 Cell
    '54444444-0000-4000-8000-000000000003'   -- EQS  hop2 동성      CAM
  );

--  · NCM 전구체(PRE-NCM, 리튬화 전 혼합수산화물 → Li 없음): Ni50.8/Co6.4/Mn5.9
UPDATE supply_chain_map SET core_minerals = '{"Ni":50.8,"Co":6.4,"Mn":5.9}'::jsonb
  WHERE edge_id IN (
    '53111111-0000-4000-8000-000000000003',  -- GLC1 hop2 청정전구체 PRE
    '53222222-0000-4000-8000-000000000003'   -- GLC2 hop2 신장제련   PRE
  );

--  · 수산화리튬(LIOH-REFINED, LiOH·H2O): Li 16.5  (기존 99는 순도지 리튬 함량이 아니라 정정)
UPDATE supply_chain_map SET core_minerals = '{"Li":16.5}'::jsonb
  WHERE edge_id IN (
    '51111111-0000-4000-8000-000000000005',  -- iX3 hop4 한중제련 LIOH
    '54444444-0000-4000-8000-000000000004'   -- EQS hop3 한중제련 LIOH
  );

--  · 리튬 원광(MIN-LI, 스포듀민 정광 ~6% Li2O 환산): Li 2.8
UPDATE supply_chain_map SET core_minerals = '{"Li":2.8}'::jsonb
  WHERE edge_id IN (
    '51111111-0000-4000-8000-000000000006',  -- iX3 hop5 호주리튬 MIN-LI
    '54444444-0000-4000-8000-000000000005'   -- EQS hop4 칠레리튬 MIN-LI
  );

-- 서사상 NULL 유지(override 안 함): i4 hop4 Unverified Trader(52222222…005), GLC2 hop3 Global Mining(53222222…004).

-- 공장별 탄소발자국 선언 (EU 배터리법 ART7)
-- 기존 공급사 단위 carbon_intensity → 공장 단위 선언으로 이관.
-- 대성정밀 화성공장(f4)은 의도적으로 미INSERT → ART7 선언 누락 → needs_human_review 트리거 유지.
INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source) VALUES
('f1111111-0000-4000-8000-000000000001', 2.3400, 'PEF', '2025-01-01', '2025-01-01', 'third_party_verified'),  -- 한양셀 포항 (Happy)
('f7777777-0000-4000-8000-000000000007', 2.5100, 'PEF', '2025-01-01', '2025-01-01', 'third_party_verified'),  -- 우진배터리 울산 (Happy)
('f2222222-0000-4000-8000-000000000002', 3.1000, 'PEF', '2025-01-01', '2025-01-01', 'supplier_declared');     -- 동성머티리얼 천안


-- ============================================================
-- 12. 운영 / 배치 (영역 9) — 4제품 배치
-- ============================================================
-- ① iX3 [Happy] EU向 발행완료
INSERT INTO batches (batch_id, product_id, bom_version_id, tenant_id, destination, current_stage, status, confidence_score, source_system, external_id) VALUES
('ba111111-0000-4000-8000-000000000001', 'd1111111-0000-4000-8000-000000000001', 'e1111111-0000-4000-8000-000000000001', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'EU', 'stage_risk',   'batch_completed', 0.9600, 'MES', 'MES-LOT-IX3'),
-- ② i4 [Gray] EU向 저신뢰 → HITL 대기
('ba222222-0000-4000-8000-000000000002', 'd2222222-0000-4000-8000-000000000002', 'e2222222-0000-4000-8000-000000000002', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'EU', 'stage_compliance', 'batch_hitl_wait',  0.7000, 'MES', 'MES-LOT-I4'),
-- ③ GLC Lot2 [Sad] US向 risk 70+ → HITL 반려 예정
('ba333333-0000-4000-8000-000000000003', 'd3333333-0000-4000-8000-000000000003', 'e3333333-0000-4000-8000-000000000032', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'US', 'stage_risk',       'batch_hitl_wait',  0.9100, 'MES', 'MES-LOT-GLC2'),
-- ④ EQS [Happy] EU向 발행완료
('ba444444-0000-4000-8000-000000000004', 'd4444444-0000-4000-8000-000000000004', 'e4444444-0000-4000-8000-000000000004', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'EU', 'stage_risk',   'batch_completed', 0.9500, 'MES', 'MES-LOT-EQS');

-- ------------------------------------------------------------
-- 종합 판정(batch_final_judgment) — 공급망 맵 '평가 리포트' 문구의 SSOT.
--   agents/final_judgment.py(render_summary/render_key_risks/RECOMMENDED_ACTIONS)가
--   생성하는 것과 동일 형식. 배치는 bom_version_id로 공급망 맵과 연결되므로,
--   프론트 공급망 맵/PageContent가 이 문구를 product×BOM 기준으로 끌어와 노출한다.
-- ------------------------------------------------------------
INSERT INTO batch_final_judgment (batch_id, overall_verdict, executive_summary, key_risks, recommended_action, confidence) VALUES
-- ① iX3 [Happy] — 전 규제 통과
('ba111111-0000-4000-8000-000000000001', 'pass',
 '이 배치는 규제 1건을 모두 통과해 적합(pass) 판정입니다.',
 '[]'::jsonb,
 '이상 없음 — 승인 진행', 0.9600),
-- ② i4 [Gray] — 회색지대/위험 신호
('ba222222-0000-4000-8000-000000000002', 'conditional',
 '이 배치는 회색지대/위험 신호(1건)로 조건부(conditional) 판정입니다.',
 '["회색지대/위험 신호 1건"]'::jsonb,
 '회색지대/위험 신호 존재 — HITL 심사 후 조건부 승인 검토', 0.7000),
-- ③ GLC Lot2 [Sad] — UFLPA 위반 + 신장 지리 위험
('ba333333-0000-4000-8000-000000000003', 'fail',
 '이 배치는 규제 위반 1건으로 부적합(fail) 판정입니다. 지리 위험: xinjiang_forced_labor.',
 '["규제 위반 1건", "지리 위험: xinjiang_forced_labor"]'::jsonb,
 '규제 위반 확인 — 배치 반려 및 협력사 시정조치(CAPA) 요구', 0.9100),
-- ④ EQS [Happy] — 전 규제 통과
('ba444444-0000-4000-8000-000000000004', 'pass',
 '이 배치는 규제 1건을 모두 통과해 적합(pass) 판정입니다.',
 '[]'::jsonb,
 '이상 없음 — 승인 진행', 0.9500);


-- ============================================================
-- 13. 규제 / 컴플라이언스 (영역 10) — 배치별 판정
-- ============================================================
-- ① iX3 [Happy] EU 통과
INSERT INTO compliance_results (batch_id, regulation_id, supplier_id, verdict, needs_human_review, cited_clauses, confidence_score, reasoning_text)
SELECT 'ba111111-0000-4000-8000-000000000001', regulation_id, 'a1111111-1111-4000-8000-000000000001', 'compliance_passed', FALSE, '["EU 2023/1542 Art.7"]'::jsonb, 0.96, '탄소발자국 신고 정상'
FROM regulations WHERE regulation_code = 'EU_BATTERY_ART7';

-- ④ EQS [Happy] EU 통과
INSERT INTO compliance_results (batch_id, regulation_id, supplier_id, verdict, needs_human_review, cited_clauses, confidence_score, reasoning_text)
SELECT 'ba444444-0000-4000-8000-000000000004', regulation_id, 'a7777777-7777-4000-8000-000000000007', 'compliance_passed', FALSE, '["EU 2023/1542 Art.7"]'::jsonb, 0.95, '탄소발자국 신고 정상'
FROM regulations WHERE regulation_code = 'EU_BATTERY_ART7';

-- ② i4 [Gray] EU_BATTERY 회색지대 (needs_human_review)
INSERT INTO compliance_results (batch_id, regulation_id, supplier_id, verdict, needs_human_review, cited_clauses, confidence_score, reasoning_text)
SELECT 'ba222222-0000-4000-8000-000000000002', regulation_id, 'a4444444-4444-4000-8000-000000000004', 'compliance_warning', TRUE, '["EU 2023/1542"]'::jsonb, 0.70, '전구체 원산지 미확인 — 사람 검토 필요'
FROM regulations WHERE regulation_code = 'EU_BATTERY';

-- ③ GLC Lot2 [Sad] UFLPA 위반
INSERT INTO compliance_results (batch_id, regulation_id, supplier_id, verdict, needs_human_review, cited_clauses, confidence_score, reasoning_text)
SELECT 'ba333333-0000-4000-8000-000000000003', regulation_id, 'a5555555-5555-4000-8000-000000000005', 'compliance_violation', FALSE, '["UFLPA Sec.3"]'::jsonb, 0.93, '신장 강제노동 의혹 — 위반'
FROM regulations WHERE regulation_code = 'UFLPA';

-- ③ GLC Lot2 [Sad] EU 배터리 탄소발자국 위반 (신고 탄소집약도 기준 초과)
--   근거: Global Mining 제출 탄소발자국 증빙(da555555)의 carbon_intensity 18.7 > 기준 16.
INSERT INTO compliance_results (batch_id, regulation_id, supplier_id, verdict, needs_human_review, cited_clauses, confidence_score, reasoning_text)
SELECT 'ba333333-0000-4000-8000-000000000003', regulation_id, 'a5555555-5555-4000-8000-000000000005', 'compliance_violation', FALSE, '["EU 2023/1542 Art.7"]'::jsonb, 0.93, '신고 탄소집약도 18.7 kgCO2e/kWh — 기준 16 초과, 화석연료(석탄) 기반 검증 불일치'
FROM regulations WHERE regulation_code = 'EU_BATTERY_ART7';


-- ============================================================
-- 13-B. W5 C1 — 규제별 필수 필드 명세 시드 (regulation_required_fields)
-- ============================================================
-- EU_BATTERY_ART7 (Art.7 / Annex II — 탄소발자국)
INSERT INTO regulation_required_fields (regulation_id, field_name, field_type, provider_type_applicable, is_mandatory)
SELECT regulation_id, 'carbon_intensity', 'numeric', '["manufacturer"]'::jsonb, TRUE
FROM regulations WHERE regulation_code = 'EU_BATTERY_ART7';

INSERT INTO regulation_required_fields (regulation_id, field_name, field_type, provider_type_applicable, is_mandatory)
SELECT regulation_id, 'factory_carbon_declarations', 'jsonb', '["manufacturer"]'::jsonb, TRUE
FROM regulations WHERE regulation_code = 'EU_BATTERY_ART7';

-- EUDR (삼림벌채 — GPS)
INSERT INTO regulation_required_fields (regulation_id, field_name, field_type, provider_type_applicable, is_mandatory)
SELECT regulation_id, 'mine_coordinates', 'geojson', '["miner"]'::jsonb, TRUE
FROM regulations WHERE regulation_code = 'EUDR';

-- UFLPA (강제노동 위험 플래그)
INSERT INTO regulation_required_fields (regulation_id, field_name, field_type, provider_type_applicable, is_mandatory)
SELECT regulation_id, 'geo_risk_flags', 'jsonb', '["miner"]'::jsonb, FALSE
FROM regulations WHERE regulation_code = 'UFLPA';


-- ============================================================
-- 14. 데이터 흐름 / Submission (영역 11)
-- ============================================================
INSERT INTO data_request_log (request_id, requester_user_id, target_supplier_id, requested_data_type, requested_at, due_date, response_status, submission_status) VALUES
('da111111-0000-4000-8000-000000000001', '11111111-0000-4000-8000-000000000002', 'a1111111-1111-4000-8000-000000000001', '탄소발자국 증빙', now() - interval '15 days', now() - interval '1 day', 'response_responded', 'submission_approved'),
('da444444-0000-4000-8000-000000000004', '11111111-0000-4000-8000-000000000002', 'a4444444-4444-4000-8000-000000000004', '공장 정보',       now() - interval '6 days',  now() + interval '8 days', 'response_responded', 'submission_rework'),
('daababab-0000-4000-8000-0000000000ab', '11111111-0000-4000-8000-000000000002', 'abababab-abab-4000-8000-0000000000ab', '원산지 증빙',     now() - interval '22 days', now() - interval '8 days', 'response_escalated', 'submission_requested'),
('da555555-0000-4000-8000-000000000005', '11111111-0000-4000-8000-000000000002', 'a5555555-5555-4000-8000-000000000005', '탄소발자국 증빙', now() - interval '5 days',  now() - interval '1 day',  'response_responded', 'submission_submitted');

INSERT INTO submission_documents (document_id, request_id, supplier_id, file_url, file_name, file_type, doc_category, file_hash, uploaded_by) VALUES
('d0c11111-0000-4000-8000-000000000001', 'da111111-0000-4000-8000-000000000001', 'a1111111-1111-4000-8000-000000000001', 's3://kira-docs/hy_carbon.pdf',  'hy_carbon.pdf',  'pdf',  'carbon_footprint_declaration', 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90', '11111111-0000-4000-8000-000000000004'),
('d0c44444-0000-4000-8000-000000000004', 'da444444-0000-4000-8000-000000000004', 'a4444444-4444-4000-8000-000000000004', 's3://kira-docs/ds_factory.xlsx','ds_factory.xlsx','xlsx', 'product_spec', 'b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1', '11111111-0000-4000-8000-000000000006'),
('d0c44444-0000-4000-8000-000000000044', 'da444444-0000-4000-8000-000000000004', 'a4444444-4444-4000-8000-000000000004', 's3://kira-docs/ds_process.pdf', 'ds_process.pdf', 'pdf',  'manufacturing_process_doc', 'd4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3', '11111111-0000-4000-8000-000000000006'),
('d0c55555-0000-4000-8000-000000000005', 'da555555-0000-4000-8000-000000000005', 'a5555555-5555-4000-8000-000000000005', 's3://kira-docs/gm_carbon.pdf',  'gm_carbon.pdf',  'pdf',  'carbon_footprint_declaration', 'c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2', '11111111-0000-4000-8000-000000000004');

INSERT INTO document_extraction_results (request_id, document_id, parsed_fields, confidence_map, unparsed_fields, supplier_confirmed, confirmed_at) VALUES
('da111111-0000-4000-8000-000000000001', 'd0c11111-0000-4000-8000-000000000001', '{"carbon_intensity":2.34,"energy_source":"renewable"}'::jsonb, '{"carbon_intensity":0.96,"energy_source":0.91}'::jsonb, '[]'::jsonb, TRUE, now() - interval '2 days'),
('da444444-0000-4000-8000-000000000004', 'd0c44444-0000-4000-8000-000000000004', '{"factory_name":"화성 공장","capacity":"2GWh"}'::jsonb, '{"factory_name":0.95,"capacity":0.62}'::jsonb, '["energy_source"]'::jsonb, FALSE, NULL),
('da555555-0000-4000-8000-000000000005', 'd0c55555-0000-4000-8000-000000000005', '{"carbon_intensity":18.7,"energy_source":"coal"}'::jsonb, '{"carbon_intensity":0.93,"energy_source":0.9}'::jsonb, '[]'::jsonb, TRUE, now() - interval '1 day');

INSERT INTO submission_status_history (request_id, from_status, to_status, actor_id, reason) VALUES
('da111111-0000-4000-8000-000000000001', 'submission_submitted', 'submission_approved', '11111111-0000-4000-8000-000000000002', '검토 통과'),
('da444444-0000-4000-8000-000000000004', 'submission_review',    'submission_rework',  '11111111-0000-4000-8000-000000000002', '자료 보완 요청');

INSERT INTO data_completeness_status (entity_type, entity_id, required_field_count, filled_field_count, completion_rate, missing_fields, last_updated_by) VALUES
('supplier', 'a1111111-1111-4000-8000-000000000001', 12, 11, 91.67, '[]'::jsonb, '11111111-0000-4000-8000-000000000002'),
('supplier', 'a4444444-4444-4000-8000-000000000004', 12, 7,  58.33, '["energy_source","cert"]'::jsonb, '11111111-0000-4000-8000-000000000002');

INSERT INTO notifications (user_id, channel, notification_type, subject, body, status, dedup_key) VALUES
('11111111-0000-4000-8000-000000000005', 'email', 'sla_warning', 'SLA 임박', '원산지 증빙 제출 기한이 지났습니다', 'pending', 'sla_reminder:daababab:2026-05-29');


-- ============================================================
-- 15. 감사 추적 / HITL (영역 12)
-- ============================================================
-- HITL: ③ Sad=risk_escalated 반려예정 / ② Gray=gray_zone 검토대기
INSERT INTO hitl_reviews (review_id, batch_id, reason, trigger_stage, assigned_to, status) VALUES
('41111111-0000-4000-8000-000000000003', 'ba333333-0000-4000-8000-000000000003', 'risk_escalated', 'stage_risk',       '11111111-0000-4000-8000-000000000002', 'hitl_pending'),
('41111111-0000-4000-8000-000000000002', 'ba222222-0000-4000-8000-000000000002', 'gray_zone',      'stage_compliance', '11111111-0000-4000-8000-000000000002', 'hitl_pending');

-- 감사 해시체인 (iX3 Happy 최소 예시)
INSERT INTO audit_trail (batch_id, step_number, node_type, node_name, input_hash, output_hash, prev_hash, duration_ms) VALUES
('ba111111-0000-4000-8000-000000000001', 1, 'agent', 'data_gateway', '0000000000000000000000000000000000000000000000000000000000000001', '0000000000000000000000000000000000000000000000000000000000000002', NULL, 120),
('ba111111-0000-4000-8000-000000000001', 2, 'agent', 'compliance',   '0000000000000000000000000000000000000000000000000000000000000002', '0000000000000000000000000000000000000000000000000000000000000003', '0000000000000000000000000000000000000000000000000000000000000002', 340);
-- ============================================================
-- TO-BE 확장 시드 (프로세스 정의서 반영)
-- ============================================================

-- 1) 다단계 결재선용 조직도(manager_id). 기존 role: admin(0001) / owner_esg(0002) / owner_purchasing(0003)
-- Admin(0001) = 최고 임원. owner_purchasing(0003) 상급자 → owner_esg(0002).
-- (002→008 결재선은 아래 SEED DELTA 블록에서 지정한다.)
UPDATE users SET manager_id = '11111111-0000-4000-8000-000000000002'
WHERE user_id = '11111111-0000-4000-8000-000000000003';

-- ===== SEED DELTA: 결재선용 부서장 추가 (02_seed_data.sql) =====
-- A 방향: role enum 변경 없음. 직책 계층(담당↔부서장)은 manager_id 로만 표현.
-- ESG 담당(002)이 컴플라이언스 보고서 기안 → ESG 부서장(008) 결재 → 끝. (2단계)

-- 1) ESG 부서장(008) 단건 INSERT (결재선 최상단, manager_id NULL).
--    001~007 은 위 라인 34 블록에서 이미 적재됨 — 재INSERT 시 PK 충돌이므로 008만 추가.
INSERT INTO users (user_id, tenant_id, email, password_hash, name, role, manager_id) VALUES
('11111111-0000-4000-8000-000000000008', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'esg.head@kira.demo',    '$2b$12$XO1O./JYL5VKDkodX2RdpOZSfFA7PSkeViaPqiOSQG4szW7fGVjf.', 'ESG Head',        'owner_esg',        NULL);

-- 2) ESG 담당(002)의 상급자를 ESG 부서장(008)으로 지정 (기안→부서장 결재 2단계).
UPDATE users SET manager_id = '11111111-0000-4000-8000-000000000008'
WHERE user_id = '11111111-0000-4000-8000-000000000002';
-- ============================================================
-- 제3자 정보제공 동의서 = 데이터 계약(Data Contract) — 한양셀 동의 완료 샘플
-- ============================================================
INSERT INTO data_provision_consents
  (supplier_id, tenant_id, data_scope, purpose, third_party_sharing, allowed_recipients, valid_from, valid_to, revocable,
   status, requested_at, returned_at, agreed_at, signer_name, signer_title, signer_email, signature_method, form_version, form_data, agreement_hash)
VALUES
  ('a1111111-1111-4000-8000-000000000001', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
   '["company","contacts","factories","carbon_epd","origin"]'::jsonb, 'EU_BATTERY', TRUE, '["BMW AG"]'::jsonb,
   '2026-01-01', '2027-12-31', TRUE, 'agreed', now() - interval '20 days', now() - interval '14 days', now() - interval '13 days',
   '김철수', 'ESG팀장', 'cs.kim@hanyangmfg.com', 'email_form', 'v1.0',
   '{"data_subject":"한양셀 제조(주)","sub_supplier_consent":true,"retention_years":7}'::jsonb, 'a3f5c9e1d2b4');

-- HITL 연동: 검토 필요 자료요청(da444444)을 gray_zone HITL 리뷰 batch에 연결(승인/반려가 hitl_reviews도 갱신).
UPDATE data_request_log SET batch_id='ba222222-0000-4000-8000-000000000002' WHERE request_id='da444444-0000-4000-8000-000000000004';


-- ============================================================
-- 16. Ingest 묶음 + 1~5차 협력사 계층 확장 (PM 요구 데이터셋)
-- ============================================================
-- [목표 개수] 위 섹션까지의 기존 데이터 대비 아래를 추가해 최종치를 맞춘다.
--   Ingest 묶음(bom_version): 기존 5 + 신규 6  = 11개
--   1차 협력사: 기존 3(한양셀·우진배터리·우진셀) + 신규 7 = 10개
--   2차 협력사: 기존 3(동성머티리얼·청정전구체·신장니켈제련) + 신규 6 = 9개
--   3차 협력사: 기존 2(한중제련·GlobalMining) + 신규 6 = 8개
--   4차 협력사: 기존 2(칠레리튬·Unverified Trader) + 신규 5 = 7개
--   5차 협력사: 기존 1(호주리튬) + 신규 5 = 6개
--   (차수 = 각 공급망 시나리오에서 해당 협력사가 등장하는 최소 hop_level)
--
-- [신규 제품 6종] BMW iX / Mercedes EQE / Hyundai IONIQ 6 / Hyundai IONIQ 5
--                / VW ID.4 / VW ID.7 — 각각 KIRA→1차→2차→3차→4차→5차 5-hop 체인
-- [Gray 시나리오 재현] VW ID.7(B10)은 4차에서 기존 Unverified Precursor Trading(ab)을
--   재사용하고 5차 없이 종료 — i4 시나리오와 동일한 '미확인 트레이더 = 추적 단절' 패턴.
-- [Dual-source 재현] BMW iX(B5)는 1차가 삼보배터리(주력) + 신성배터리(보조·미검증)
--   2곳으로 이중 소싱 — 1차 협력사 수를 6개가 아닌 7개로 맞추는 실제 업계 패턴.
-- ============================================================

-- ── 16-1. 신규 고객사 2개 ──────────────────────────────────────
INSERT INTO customers (customer_id, customer_code, customer_name, country, source_system, external_id) VALUES
('c0000000-0000-4000-8000-0000000000b3', 'HYUNDAI', 'Hyundai Motor Company', 'KR', 'ERP_PLM', 'ERP-CUST-HMC'),
('c0000000-0000-4000-8000-0000000000b4', 'VW',      'Volkswagen AG',         'DE', 'ERP_PLM', 'ERP-CUST-VWG');

-- ── 16-2. 신규 제품 6개 ────────────────────────────────────────
INSERT INTO products (product_id, product_code, product_name, manufacturer_id, tenant_id, customer_id, model_name, amperage_ah, type, source_system, external_id) VALUES
('d5555555-0000-4000-8000-000000000005', 'KE-PRI-NCM-100', 'KIRA PRiMX Prismatic NCM 100Ah', 'a0000000-0000-4000-8000-000000000000', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'c0000000-0000-4000-8000-0000000000b1', 'iX',      100.00, 'battery_pack', 'ERP_PLM', 'ERP-PROD-IX'),
('d6666666-0000-4000-8000-000000000006', 'KE-PRI-NCM-096', 'KIRA PRiMX Prismatic NCM 96Ah',  'a0000000-0000-4000-8000-000000000000', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'c0000000-0000-4000-8000-0000000000b2', 'EQE',      96.00, 'battery_pack', 'ERP_PLM', 'ERP-PROD-EQE'),
('d7777777-0000-4000-8000-000000000007', 'KE-CYL-NCM-095', 'KIRA PRiMX Cylindrical NCM 95Ah','a0000000-0000-4000-8000-000000000000', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'c0000000-0000-4000-8000-0000000000b3', 'IONIQ 6',  95.00, 'battery_pack', 'ERP_PLM', 'ERP-PROD-I6'),
('d8888888-0000-4000-8000-000000000008', 'KE-PRI-NCM-084', 'KIRA PRiMX Prismatic NCM 84Ah',  'a0000000-0000-4000-8000-000000000000', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'c0000000-0000-4000-8000-0000000000b3', 'IONIQ 5',  84.00, 'battery_pack', 'ERP_PLM', 'ERP-PROD-I5'),
('d9999999-0000-4000-8000-000000000009', 'KE-PRI-NCM-082', 'KIRA PRiMX Prismatic NCM 82Ah',  'a0000000-0000-4000-8000-000000000000', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'c0000000-0000-4000-8000-0000000000b4', 'ID.4',     82.00, 'battery_pack', 'ERP_PLM', 'ERP-PROD-ID4'),
('daaaaaaa-0000-4000-8000-00000000000a', 'KE-PRI-NCM-110', 'KIRA PRiMX Prismatic NCM 110Ah', 'a0000000-0000-4000-8000-000000000000', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'c0000000-0000-4000-8000-0000000000b4', 'ID.7',    110.00, 'battery_pack', 'ERP_PLM', 'ERP-PROD-ID7');

-- ── 16-3. 신규 BOM 버전 6개 (= Ingest 묶음 5→11) ─────────────────
INSERT INTO bom_versions (bom_version_id, product_id, version_number, production_from, production_to, status, source_system, external_id) VALUES
('e5555555-0000-4000-8000-000000000005', 'd5555555-0000-4000-8000-000000000005', 'Gen5-R1', '2024-07-01', NULL,         'active',    'ERP_PLM', 'ERP-BOM-IX'),
('e6666666-0000-4000-8000-000000000006', 'd6666666-0000-4000-8000-000000000006', 'Rev.A',   '2024-04-01', NULL,         'active',    'ERP_PLM', 'ERP-BOM-EQE'),
('e7777777-0000-4000-8000-000000000007', 'd7777777-0000-4000-8000-000000000007', 'v3.1',    '2024-01-01', '2024-12-31', 'deprecated','ERP_PLM', 'ERP-BOM-I6'),
('e8888888-0000-4000-8000-000000000008', 'd8888888-0000-4000-8000-000000000008', 'Rev.B',   '2024-03-01', NULL,         'active',    'ERP_PLM', 'ERP-BOM-I5'),
('e9999999-0000-4000-8000-000000000009', 'd9999999-0000-4000-8000-000000000009', 'v1.2',    '2024-06-01', '2024-12-31', 'deprecated','ERP_PLM', 'ERP-BOM-ID4'),
('eaaaaaaa-0000-4000-8000-00000000000a', 'daaaaaaa-0000-4000-8000-00000000000a', 'v1.0',    '2025-01-01', NULL,         'active',    'ERP_PLM', 'ERP-BOM-ID7');


-- ============================================================
-- 16-4. 1차 협력사 — 신규 7개 (기준정보: 회사명/사업자등록번호/주소/provider_type/
--        핵심광물+유해물질/서류 URL) + 공장 + PIC 3명 + 제조상세 + 탄소선언 + 리스크
-- ============================================================
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, company_name_ko, ceo_name, business_reg_no, provider_type, core_minerals, country, address, business_reg_doc_url, environmental_report_url, self_assessment_doc_url, completeness_score, status, risk_level) VALUES
('61111111-0000-4000-8000-000000000001', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '삼보배터리(주)', 'Sambo Battery Co.', '삼보배터리(주)', 'Park JH CEO', '111-86-11111', 'manufacturer', '{"Li":7.2,"Ni":80.0,"Co":10.0,"Mn":10.0,"hazardous_substances":["Pb","Cd"]}'::jsonb, 'KR', '경기도 평택시 포승읍 산업단지로 120', 's3://kira-docs/suppliers/61111111/biz_reg.pdf', 's3://kira-docs/suppliers/61111111/env_report.pdf', 's3://kira-docs/suppliers/61111111/self_assess.pdf', 88, 'supplier_verified', 'low'),
('61222222-0000-4000-8000-000000000002', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '하나에너지셀(주)', 'Hana Energy Cell Corp', '하나에너지셀(주)', 'Choi SY CEO', '222-86-11122', 'manufacturer', '{"Li":7.0,"Ni":80.0,"Co":10.0,"Mn":10.0}'::jsonb, 'KR', '충청북도 청주시 흥덕구 오송읍 오송산단로 55', 's3://kira-docs/suppliers/61222222/biz_reg.pdf', 's3://kira-docs/suppliers/61222222/env_report.pdf', 's3://kira-docs/suppliers/61222222/self_assess.pdf', 91, 'supplier_verified', 'low'),
('61333333-0000-4000-8000-000000000003', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '성진셀(주)', 'Sungjin Cell Co.', '성진셀(주)', 'Kim DH CEO', '333-86-11133', 'manufacturer', '{"Li":7.1,"Ni":79.0,"Co":11.0,"Mn":10.0}'::jsonb, 'KR', '경상남도 창원시 성산구 공단로 88', 's3://kira-docs/suppliers/61333333/biz_reg.pdf', 's3://kira-docs/suppliers/61333333/env_report.pdf', 's3://kira-docs/suppliers/61333333/self_assess.pdf', 85, 'supplier_verified', 'low'),
('61444444-0000-4000-8000-000000000004', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '동아셀(주)', 'Donga Cell Corp', '동아셀(주)', 'Lee SB CEO', '444-86-11144', 'manufacturer', '{"Li":7.0,"Ni":78.5,"Co":11.5,"Mn":10.0}'::jsonb, 'KR', '전라남도 광양시 광양읍 산단1로 200', 's3://kira-docs/suppliers/61444444/biz_reg.pdf', 's3://kira-docs/suppliers/61444444/env_report.pdf', NULL, 78, 'supplier_in_progress', 'low'),
('61555555-0000-4000-8000-000000000005', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '한독배터리(주)', 'Handok Battery Co.', '한독배터리(주)', 'Jung KW CEO', '555-86-11155', 'manufacturer', '{"Li":7.3,"Ni":80.0,"Co":10.0,"Mn":10.0}'::jsonb, 'KR', '경상북도 구미시 산동읍 구미국가산단로 350', 's3://kira-docs/suppliers/61555555/biz_reg.pdf', 's3://kira-docs/suppliers/61555555/env_report.pdf', 's3://kira-docs/suppliers/61555555/self_assess.pdf', 93, 'supplier_verified', 'low'),
('61666666-0000-4000-8000-000000000006', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '고려에너지(주)', 'Koryo Energy Corp', '고려에너지(주)', 'Han MJ CEO', '666-86-11166', 'manufacturer', '{"Li":7.0,"Ni":80.0,"Co":10.0,"Mn":10.0}'::jsonb, 'KR', '인천광역시 남동구 남동공단로 99', 's3://kira-docs/suppliers/61666666/biz_reg.pdf', 's3://kira-docs/suppliers/61666666/env_report.pdf', 's3://kira-docs/suppliers/61666666/self_assess.pdf', 87, 'supplier_verified', 'low'),
-- 신성배터리: BMW iX(B5) 이중소싱 보조 1차사 — 온보딩 초기(서류 미비) 상태로 재현
('61777777-0000-4000-8000-000000000007', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '신성배터리(주)', 'Shinsung Battery Co.', '신성배터리(주)', 'Oh JH CEO', '777-86-11177', 'manufacturer', NULL, 'KR', '경기도 화성시 향남읍 향남로 175', 's3://kira-docs/suppliers/61777777/biz_reg.pdf', NULL, NULL, 42, 'supplier_in_progress', 'low');

INSERT INTO supplier_factories (factory_id, supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent) VALUES
('71111111-0000-4000-8000-000000000001', '61111111-0000-4000-8000-000000000001', '평택 제1공장', 'Pyeongtaek Plant 1', 'KR', 'Pyeongtaek', ST_SetSRID(ST_MakePoint(126.996, 36.993), 4326), 'production', 'EU',   '["EU_BATTERY","EU_BATTERY_ART7","EU_BATTERY_ART47","CSDDD"]'::jsonb, 100.00),
('71222222-0000-4000-8000-000000000002', '61222222-0000-4000-8000-000000000002', '오송 셀공장',  'Osong Cell Plant',   'KR', 'Cheongju',  ST_SetSRID(ST_MakePoint(127.344, 36.634), 4326), 'production', 'EU',   '["EU_BATTERY","EU_BATTERY_ART7","CSDDD"]'::jsonb, 100.00),
('71333333-0000-4000-8000-000000000003', '61333333-0000-4000-8000-000000000003', '창원 원통형공장','Changwon Cylindrical Plant','KR', 'Changwon', ST_SetSRID(ST_MakePoint(128.681, 35.228), 4326), 'production', 'EU',   '["EU_BATTERY","EU_BATTERY_ART7","CSDDD"]'::jsonb, 100.00),
('71444444-0000-4000-8000-000000000004', '61444444-0000-4000-8000-000000000004', '광양 공장',   'Gwangyang Plant',    'KR', 'Gwangyang', ST_SetSRID(ST_MakePoint(127.694, 34.940), 4326), 'production', 'EU',   '["EU_BATTERY","EU_BATTERY_ART7"]'::jsonb, 100.00),
('71555555-0000-4000-8000-000000000005', '61555555-0000-4000-8000-000000000005', '구미 배터리공장','Gumi Battery Plant','KR', 'Gumi',     ST_SetSRID(ST_MakePoint(128.319, 36.119), 4326), 'production', 'BOTH', '["EU_BATTERY","EU_BATTERY_ART7","EU_BATTERY_ART47","CSDDD"]'::jsonb, 100.00),
('71666666-0000-4000-8000-000000000006', '61666666-0000-4000-8000-000000000006', '인천 공장',   'Incheon Plant',      'KR', 'Incheon',   ST_SetSRID(ST_MakePoint(126.727, 37.454), 4326), 'production', 'BOTH', '["EU_BATTERY","EU_BATTERY_ART7","CSDDD"]'::jsonb, 100.00),
('71777777-0000-4000-8000-000000000007', '61777777-0000-4000-8000-000000000007', '화성 공장',   'Hwaseong Plant',     'KR', 'Hwaseong',  ST_SetSRID(ST_MakePoint(126.831, 37.199), 4326), 'production', 'EU',   '["EU_BATTERY"]'::jsonb, 100.00);

-- PIC 3명씩 (신성배터리는 온보딩 초기라 1명만 — 실제 운영 상태 재현)
INSERT INTO supplier_contacts (supplier_id, factory_id, name, name_en, role, department, email, phone, is_primary, language) VALUES
('61111111-0000-4000-8000-000000000001', '71111111-0000-4000-8000-000000000001', '박지훈', 'Park JH', 'ESG Manager', 'ESG팀', 'jh.park@sambo.demo', '+82-31-111-0001', TRUE, 'ko'),
('61111111-0000-4000-8000-000000000001', '71111111-0000-4000-8000-000000000001', '김수영', 'Kim SY', 'Quality Manager', '품질관리팀', 'sy.kim@sambo.demo', '+82-31-111-0002', FALSE, 'ko'),
('61111111-0000-4000-8000-000000000001', '71111111-0000-4000-8000-000000000001', '이정민', 'Lee JM', 'Compliance Officer', '법무팀', 'jm.lee@sambo.demo', '+82-31-111-0003', FALSE, 'ko'),
('61222222-0000-4000-8000-000000000002', '71222222-0000-4000-8000-000000000002', '최선영', 'Choi SY', 'ESG Team Lead', 'ESG팀', 'sy.choi@hanaenergy.demo', '+82-43-222-0001', TRUE, 'ko'),
('61222222-0000-4000-8000-000000000002', '71222222-0000-4000-8000-000000000002', '오민준', 'Oh MJ', 'Plant Manager', '생산기술팀', 'mj.oh@hanaenergy.demo', '+82-43-222-0002', FALSE, 'ko'),
('61222222-0000-4000-8000-000000000002', '71222222-0000-4000-8000-000000000002', '신하은', 'Shin HE', 'Safety Manager', '안전환경팀', 'he.shin@hanaenergy.demo', '+82-43-222-0003', FALSE, 'ko'),
('61333333-0000-4000-8000-000000000003', '71333333-0000-4000-8000-000000000003', '김동현', 'Kim DH', 'ESG Officer', 'ESG팀', 'dh.kim@sungjincell.demo', '+82-55-333-0001', TRUE, 'ko'),
('61333333-0000-4000-8000-000000000003', '71333333-0000-4000-8000-000000000003', '정유진', 'Jung YJ', 'Purchasing Manager', '구매팀', 'yj.jung@sungjincell.demo', '+82-55-333-0002', FALSE, 'ko'),
('61333333-0000-4000-8000-000000000003', '71333333-0000-4000-8000-000000000003', '백승호', 'Baek SH', 'R&D Manager', '연구개발팀', 'sh.baek@sungjincell.demo', '+82-55-333-0003', FALSE, 'ko'),
('61444444-0000-4000-8000-000000000004', '71444444-0000-4000-8000-000000000004', '이상범', 'Lee SB', 'ESG Manager', 'ESG팀', 'sb.lee@dongacell.demo', '+82-61-444-0001', TRUE, 'ko'),
('61444444-0000-4000-8000-000000000004', '71444444-0000-4000-8000-000000000004', '강민지', 'Kang MJ', 'Quality Engineer', '품질팀', 'mj.kang@dongacell.demo', '+82-61-444-0002', FALSE, 'ko'),
('61444444-0000-4000-8000-000000000004', '71444444-0000-4000-8000-000000000004', '윤재혁', 'Yoon JH', 'Environmental Mgr', '환경팀', 'jh.yoon@dongacell.demo', '+82-61-444-0003', FALSE, 'ko'),
('61555555-0000-4000-8000-000000000005', '71555555-0000-4000-8000-000000000005', '정광우', 'Jung KW', 'ESG Director', 'ESG본부', 'kw.jung@handokbattery.demo', '+82-54-555-0001', TRUE, 'ko'),
('61555555-0000-4000-8000-000000000005', '71555555-0000-4000-8000-000000000005', 'Thomas Müller', 'Thomas Müller', 'QM Representative', 'QM부', 't.mueller@handokbattery.demo', '+82-54-555-0002', FALSE, 'en'),
('61555555-0000-4000-8000-000000000005', '71555555-0000-4000-8000-000000000005', '박혜진', 'Park HJ', 'Supply Chain Mgr', '공급망팀', 'hj.park@handokbattery.demo', '+82-54-555-0003', FALSE, 'ko'),
('61666666-0000-4000-8000-000000000006', '71666666-0000-4000-8000-000000000006', '한민지', 'Han MJ', 'ESG Team Lead', 'ESG팀', 'mj.han@koryoenergy.demo', '+82-32-666-0001', TRUE, 'ko'),
('61666666-0000-4000-8000-000000000006', '71666666-0000-4000-8000-000000000006', '송재원', 'Song JW', 'Compliance Mgr', '준법팀', 'jw.song@koryoenergy.demo', '+82-32-666-0002', FALSE, 'ko'),
('61666666-0000-4000-8000-000000000006', '71666666-0000-4000-8000-000000000006', '임수진', 'Lim SJ', 'Carbon Manager', '탄소중립팀', 'sj.lim@koryoenergy.demo', '+82-32-666-0003', FALSE, 'ko'),
('61777777-0000-4000-8000-000000000007', '71777777-0000-4000-8000-000000000007', '오준혁', 'Oh JH', 'ESG Officer', 'ESG팀', 'jh.oh@shinsungbattery.demo', '+82-31-777-0001', TRUE, 'ko');

INSERT INTO supplier_manufacturer_details (supplier_id, manufacturing_process, energy_source, capacity, carbon_intensity) VALUES
('61111111-0000-4000-8000-000000000001', 'NCM811 Prismatic Cell Assembly', 'renewable', '12GWh/yr', 2.1800),
('61222222-0000-4000-8000-000000000002', 'NCM811 Prismatic Cell Assembly', 'renewable', '9GWh/yr',  2.3100),
('61333333-0000-4000-8000-000000000003', 'NCM811 Cylindrical Cell Assembly', 'mixed',    '7GWh/yr',  2.8900),
('61444444-0000-4000-8000-000000000004', 'NCM Prismatic Cell Assembly',     'mixed',    '6GWh/yr',  3.0500),
('61555555-0000-4000-8000-000000000005', 'NCM811 Cell & Module Assembly',   'renewable','11GWh/yr', 2.2200),
('61666666-0000-4000-8000-000000000006', 'NCM811 Prismatic Cell Assembly',  'renewable','8GWh/yr',  2.4500);

INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source) VALUES
('71111111-0000-4000-8000-000000000001', 2.1800, 'PEF', '2024-07-01', '2024-07-01', 'third_party_verified'),
('71222222-0000-4000-8000-000000000002', 2.3100, 'PEF', '2024-04-01', '2024-04-01', 'third_party_verified'),
('71333333-0000-4000-8000-000000000003', 2.8900, 'PEF', '2024-01-01', '2024-01-01', 'supplier_declared'),
('71555555-0000-4000-8000-000000000005', 2.2200, 'PEF', '2024-06-01', '2024-06-01', 'third_party_verified'),
('71666666-0000-4000-8000-000000000006', 2.4500, 'PEF', '2025-01-01', '2025-01-01', 'supplier_declared');
-- 71444444(동아셀)·71777777(신성배터리): 선언 미제출 — ART7 needs_human_review 갭 재현

INSERT INTO supplier_onboarding (supplier_id, consent_status, consent_signed_at, agreement_status, last_invited_at, sla_due_date, reminder_count) VALUES
('61111111-0000-4000-8000-000000000001', 'consent_agreed',  now() - interval '30 days', 'agreed',  now() - interval '31 days', now() - interval '17 days', 0),
('61222222-0000-4000-8000-000000000002', 'consent_agreed',  now() - interval '25 days', 'agreed',  now() - interval '26 days', now() - interval '12 days', 0),
('61333333-0000-4000-8000-000000000003', 'consent_agreed',  now() - interval '20 days', 'agreed',  now() - interval '21 days', now() - interval '7 days',  0),
('61444444-0000-4000-8000-000000000004', 'consent_agreed',  now() - interval '10 days', 'agreed',  now() - interval '11 days', now() + interval '3 days',  1),
('61555555-0000-4000-8000-000000000005', 'consent_agreed',  now() - interval '35 days', 'agreed',  now() - interval '36 days', now() - interval '22 days', 0),
('61666666-0000-4000-8000-000000000006', 'consent_agreed',  now() - interval '15 days', 'agreed',  now() - interval '16 days', now() - interval '2 days',  0),
('61777777-0000-4000-8000-000000000007', 'consent_pending', NULL,                        'pending', now() - interval '3 days',  now() + interval '11 days', 0);

INSERT INTO supplier_risk_profiles (supplier_id, overall_risk_score, risk_level, self_reported_risk_level, is_high_risk_flag, last_risk_review_at) VALUES
('61111111-0000-4000-8000-000000000001', 8,  'low', 'low', FALSE, now() - interval '5 days'),
('61222222-0000-4000-8000-000000000002', 10, 'low', 'low', FALSE, now() - interval '5 days'),
('61333333-0000-4000-8000-000000000003', 12, 'low', 'low', FALSE, now() - interval '5 days'),
('61444444-0000-4000-8000-000000000004', 25, 'low', 'low', FALSE, now() - interval '5 days'),
('61555555-0000-4000-8000-000000000005', 9,  'low', 'low', FALSE, now() - interval '5 days'),
('61666666-0000-4000-8000-000000000006', 11, 'low', 'low', FALSE, now() - interval '5 days'),
('61777777-0000-4000-8000-000000000007', 20, 'low', 'low', FALSE, now() - interval '5 days');


-- ============================================================
-- 16-5. 2차 협력사 — 신규 6개 (CAM 양극재 제조사)
-- ============================================================
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, ceo_name, business_reg_no, provider_type, core_minerals, country, address, business_reg_doc_url, environmental_report_url, completeness_score, status, risk_level) VALUES
('62111111-0000-4000-8000-000000000001', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '에코양극재(주)', 'Eco Cathode Materials', 'Yoon BK CEO', '611-86-20001', 'manufacturer', '{"Ni":55.0,"Co":8.0,"Mn":7.0}'::jsonb,   'KR', '충청남도 천안시 서북구 성환읍 성환산단로 30', 's3://kira-docs/suppliers/62111111/biz_reg.pdf', 's3://kira-docs/suppliers/62111111/env_report.pdf', 82, 'supplier_verified',    'low'),
('62222222-0000-4000-8000-000000000002', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '포스피케미칼(주)', 'PospiChem Co.', 'Shin TH CEO', '622-86-20002', 'manufacturer', '{"Ni":53.0,"Co":8.5,"Mn":8.5}'::jsonb, 'KR', '경상북도 포항시 남구 오천읍 포항산단4로 10', 's3://kira-docs/suppliers/62222222/biz_reg.pdf', 's3://kira-docs/suppliers/62222222/env_report.pdf', 79, 'supplier_verified',    'low'),
('62333333-0000-4000-8000-000000000003', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '신진CAM(주)', 'Sinjin CAM Co.', 'Kwak MS CEO', '633-86-20003', 'manufacturer', '{"Ni":54.0,"Co":9.0,"Mn":8.0}'::jsonb,      'KR', '전라북도 군산시 소룡동 군산국가산단로 88', NULL,                                              NULL,                                              68, 'supplier_in_progress', 'low'),
('62444444-0000-4000-8000-000000000004', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '한라소재(주)', 'Halla Materials Co.', 'Kwon YS CEO', '644-86-20004', 'manufacturer', '{"Ni":52.0,"Co":9.5,"Mn":8.5}'::jsonb,   'KR', '경상남도 거제시 장승포동 거제산단로 15', 's3://kira-docs/suppliers/62444444/biz_reg.pdf', 's3://kira-docs/suppliers/62444444/env_report.pdf', 75, 'supplier_verified',    'low'),
('62555555-0000-4000-8000-000000000005', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '대한CAM(주)', 'Daehan CAM Co.', 'Baek JW CEO', '655-86-20005', 'manufacturer', '{"Ni":55.5,"Co":8.0,"Mn":6.5}'::jsonb,    'KR', '울산광역시 남구 매암동 울산산단로 210', 's3://kira-docs/suppliers/62555555/biz_reg.pdf', 's3://kira-docs/suppliers/62555555/env_report.pdf', 80, 'supplier_verified',    'low'),
('62666666-0000-4000-8000-000000000006', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '청우CAM(주)', 'Cheongwoo CAM Co.', 'Nam HJ CEO', '666-86-20006', 'manufacturer', '{"Ni":53.5,"Co":8.8,"Mn":7.7}'::jsonb,   'KR', '경기도 이천시 부발읍 이천산단로 44', NULL,                                              NULL,                                              60, 'supplier_in_progress', 'low');

INSERT INTO supplier_factories (factory_id, supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent) VALUES
('72111111-0000-4000-8000-000000000001', '62111111-0000-4000-8000-000000000001', '천안 양극재공장', 'Cheonan CAM Plant', 'KR', 'Cheonan', ST_SetSRID(ST_MakePoint(127.100, 36.810), 4326), 'processing', 'BOTH', '["EU_BATTERY","CRMA","EU_BATTERY_ART7"]'::jsonb, 100.00),
('72222222-0000-4000-8000-000000000002', '62222222-0000-4000-8000-000000000002', '포항 CAM공장',  'Pohang CAM Plant',  'KR', 'Pohang',  ST_SetSRID(ST_MakePoint(129.380, 36.010), 4326), 'processing', 'BOTH', '["EU_BATTERY","CRMA"]'::jsonb, 100.00),
('72333333-0000-4000-8000-000000000003', '62333333-0000-4000-8000-000000000003', '군산 CAM공장',  'Gunsan CAM Plant',  'KR', 'Gunsan',  ST_SetSRID(ST_MakePoint(126.711, 35.967), 4326), 'processing', 'EU',   '["EU_BATTERY"]'::jsonb, 100.00),
('72444444-0000-4000-8000-000000000004', '62444444-0000-4000-8000-000000000004', '거제 소재공장', 'Geoje Materials Plant','KR', 'Geoje', ST_SetSRID(ST_MakePoint(128.621, 34.879), 4326), 'processing', 'EU',   '["EU_BATTERY","CRMA"]'::jsonb, 100.00),
('72555555-0000-4000-8000-000000000005', '62555555-0000-4000-8000-000000000005', '울산 CAM공장',  'Ulsan CAM Plant',   'KR', 'Ulsan',   ST_SetSRID(ST_MakePoint(129.365, 35.520), 4326), 'processing', 'BOTH', '["EU_BATTERY","CRMA","EU_BATTERY_ART7"]'::jsonb, 100.00),
('72666666-0000-4000-8000-000000000006', '62666666-0000-4000-8000-000000000006', '이천 CAM공장',  'Icheon CAM Plant',  'KR', 'Icheon',  ST_SetSRID(ST_MakePoint(127.505, 37.246), 4326), 'processing', 'EU',   '["EU_BATTERY"]'::jsonb, 100.00);

INSERT INTO supplier_contacts (supplier_id, factory_id, name, name_en, role, department, email, phone, is_primary, language) VALUES
('62111111-0000-4000-8000-000000000001', '72111111-0000-4000-8000-000000000001', '윤병기', 'Yoon BK', 'ESG Manager', 'ESG팀', 'bk.yoon@ecocathode.demo', '+82-41-111-2001', TRUE, 'ko'),
('62222222-0000-4000-8000-000000000002', '72222222-0000-4000-8000-000000000002', '신태현', 'Shin TH', 'ESG Lead',    'ESG팀', 'th.shin@pospichem.demo',  '+82-54-222-2002', TRUE, 'ko'),
('62333333-0000-4000-8000-000000000003', '72333333-0000-4000-8000-000000000003', '곽민석', 'Kwak MS', 'ESG Officer', 'ESG팀', 'ms.kwak@sinjincam.demo',  '+82-63-333-2003', TRUE, 'ko'),
('62444444-0000-4000-8000-000000000004', '72444444-0000-4000-8000-000000000004', '권영수', 'Kwon YS', 'ESG Manager', 'ESG팀', 'ys.kwon@hallamat.demo',   '+82-55-444-2004', TRUE, 'ko'),
('62555555-0000-4000-8000-000000000005', '72555555-0000-4000-8000-000000000005', '백준우', 'Baek JW', 'ESG Manager', 'ESG팀', 'jw.baek@daehancam.demo',  '+82-52-555-2005', TRUE, 'ko'),
('62666666-0000-4000-8000-000000000006', '72666666-0000-4000-8000-000000000006', '남효진', 'Nam HJ',  'ESG Officer', 'ESG팀', 'hj.nam@cheongwoocam.demo','+82-31-666-2006', TRUE, 'ko');

INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source) VALUES
('72111111-0000-4000-8000-000000000001', 3.0500, 'PEF', '2024-01-01', '2024-01-01', 'supplier_declared'),
('72222222-0000-4000-8000-000000000002', 3.2100, 'PEF', '2024-01-01', '2024-01-01', 'supplier_declared'),
('72444444-0000-4000-8000-000000000004', 3.1200, 'PEF', '2024-01-01', '2024-01-01', 'supplier_declared'),
('72555555-0000-4000-8000-000000000005', 2.9500, 'PEF', '2024-01-01', '2024-01-01', 'supplier_declared');
-- 72333333(신진CAM)·72666666(청우CAM): 선언 미제출 갭

INSERT INTO supplier_risk_profiles (supplier_id, overall_risk_score, risk_level, self_reported_risk_level, is_high_risk_flag, last_risk_review_at) VALUES
('62111111-0000-4000-8000-000000000001', 14, 'low', 'low', FALSE, now() - interval '7 days'),
('62222222-0000-4000-8000-000000000002', 18, 'low', 'low', FALSE, now() - interval '7 days'),
('62333333-0000-4000-8000-000000000003', 22, 'low', 'low', FALSE, now() - interval '7 days'),
('62444444-0000-4000-8000-000000000004', 19, 'low', 'low', FALSE, now() - interval '7 days'),
('62555555-0000-4000-8000-000000000005', 15, 'low', 'low', FALSE, now() - interval '7 days'),
('62666666-0000-4000-8000-000000000006', 24, 'low', 'low', FALSE, now() - interval '7 days');


-- ============================================================
-- 16-6. 3차 협력사 — 신규 6개 (전구체 제조사)
-- ============================================================
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, ceo_name, business_reg_no, provider_type, core_minerals, country, address, business_reg_doc_url, environmental_report_url, completeness_score, status, risk_level) VALUES
('63111111-0000-4000-8000-000000000001', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '동신전구체(주)', 'Dongsin Precursor Corp', 'Bae CW CEO', '611-86-30001', 'manufacturer', '{"Ni":50.0,"Co":10.0,"Mn":10.0}'::jsonb, 'KR', '전라북도 군산시 소룡동 군산국가산단로 90', 's3://kira-docs/suppliers/63111111/biz_reg.pdf', 's3://kira-docs/suppliers/63111111/env_report.pdf', 74, 'supplier_verified',    'low'),
('63222222-0000-4000-8000-000000000002', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '대성전구체(주)', 'Daesung Precursor Materials', 'Han SK CEO', '622-86-30002', 'manufacturer', '{"Ni":48.0,"Co":11.0,"Mn":11.0}'::jsonb, 'KR', '경기도 화성시 정남면 화성산단로 60', NULL, NULL, 55, 'supplier_review', 'medium'),
('63333333-0000-4000-8000-000000000003', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '한중정밀화학(주)', 'Hanjung Precision Chemical', 'Ma YL CEO', '633-86-30003', 'manufacturer', '{"Ni":51.0,"Co":9.5,"Mn":9.5}'::jsonb, 'KR', '경상북도 포항시 남구 포항산단로 200', 's3://kira-docs/suppliers/63333333/biz_reg.pdf', 's3://kira-docs/suppliers/63333333/env_report.pdf', 76, 'supplier_verified', 'low'),
('63444444-0000-4000-8000-000000000004', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '세종프리커서(주)', 'Sejong Precursor Co.', 'Cho HY CEO', '644-86-30004', 'manufacturer', '{"Ni":49.5,"Co":10.5,"Mn":10.0}'::jsonb, 'KR', '세종특별자치시 소정면 세종산단로 15', 's3://kira-docs/suppliers/63444444/biz_reg.pdf', 's3://kira-docs/suppliers/63444444/env_report.pdf', 71, 'supplier_verified', 'low'),
('63555555-0000-4000-8000-000000000005', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '남해케미칼(주)', 'Namhae Chemical Co.', 'Yang JS CEO', '655-86-30005', 'manufacturer', '{"Ni":50.5,"Co":9.8,"Mn":9.7}'::jsonb, 'KR', '경상남도 남해군 서면 남해산단로 8', NULL, NULL, 58, 'supplier_in_progress', 'low'),
('63666666-0000-4000-8000-000000000006', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '은성정밀소재(주)', 'Eunsung Precision Materials', 'Ko DW CEO', '666-86-30006', 'manufacturer', '{"Ni":52.5,"Co":9.0,"Mn":8.5}'::jsonb, 'KR', '충청남도 아산시 인주면 아산산단로 33', 's3://kira-docs/suppliers/63666666/biz_reg.pdf', 's3://kira-docs/suppliers/63666666/env_report.pdf', 73, 'supplier_verified', 'low');

INSERT INTO supplier_factories (factory_id, supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent) VALUES
('73111111-0000-4000-8000-000000000001', '63111111-0000-4000-8000-000000000001', '군산 전구체공장', 'Gunsan Precursor Plant', 'KR', 'Gunsan',   ST_SetSRID(ST_MakePoint(126.715, 35.965), 4326), 'processing', 'EU',   '["EU_BATTERY","CRMA"]'::jsonb, 100.00),
('73222222-0000-4000-8000-000000000002', '63222222-0000-4000-8000-000000000002', '화성 전구체공장', 'Hwaseong Precursor Plant', 'KR', 'Hwaseong', ST_SetSRID(ST_MakePoint(126.850, 37.170), 4326), 'processing', 'EU',   '["EU_BATTERY"]'::jsonb, 100.00),
('73333333-0000-4000-8000-000000000003', '63333333-0000-4000-8000-000000000003', '포항 정밀화학공장', 'Pohang Precision Chem Plant', 'KR', 'Pohang', ST_SetSRID(ST_MakePoint(129.375, 36.005), 4326), 'processing', 'BOTH', '["EU_BATTERY","CRMA"]'::jsonb, 100.00),
('73444444-0000-4000-8000-000000000004', '63444444-0000-4000-8000-000000000004', '세종 전구체공장', 'Sejong Precursor Plant', 'KR', 'Sejong',   ST_SetSRID(ST_MakePoint(127.290, 36.480), 4326), 'processing', 'EU',   '["EU_BATTERY"]'::jsonb, 100.00),
('73555555-0000-4000-8000-000000000005', '63555555-0000-4000-8000-000000000005', '남해 케미칼공장', 'Namhae Chemical Plant', 'KR', 'Namhae',   ST_SetSRID(ST_MakePoint(127.865, 34.870), 4326), 'processing', 'EU',   '["EU_BATTERY"]'::jsonb, 100.00),
('73666666-0000-4000-8000-000000000006', '63666666-0000-4000-8000-000000000006', '아산 정밀소재공장', 'Asan Precision Materials Plant', 'KR', 'Asan', ST_SetSRID(ST_MakePoint(126.960, 36.780), 4326), 'processing', 'BOTH', '["EU_BATTERY","CRMA"]'::jsonb, 100.00);

INSERT INTO supplier_contacts (supplier_id, factory_id, name, name_en, role, department, email, phone, is_primary, language) VALUES
('63111111-0000-4000-8000-000000000001', '73111111-0000-4000-8000-000000000001', '배창우', 'Bae CW', 'ESG Officer', 'ESG팀', 'cw.bae@dongsinpre.demo',  '+82-63-111-3001', TRUE, 'ko'),
('63222222-0000-4000-8000-000000000002', '73222222-0000-4000-8000-000000000002', '한상국', 'Han SK', 'ESG Officer', 'ESG팀', 'sk.han@daesungpre.demo',  '+82-31-222-3002', TRUE, 'ko'),
('63333333-0000-4000-8000-000000000003', '73333333-0000-4000-8000-000000000003', '마영림', 'Ma YL',  'ESG Officer', 'ESG팀', 'yl.ma@hanjungchem.demo',  '+82-54-333-3003', TRUE, 'ko'),
('63444444-0000-4000-8000-000000000004', '73444444-0000-4000-8000-000000000004', '조현영', 'Cho HY', 'ESG Manager', 'ESG팀', 'hy.cho@sejongpre.demo',   '+82-44-444-3004', TRUE, 'ko'),
('63555555-0000-4000-8000-000000000005', '73555555-0000-4000-8000-000000000005', '양지수', 'Yang JS','ESG Officer', 'ESG팀', 'js.yang@namhaechem.demo', '+82-55-555-3005', TRUE, 'ko'),
('63666666-0000-4000-8000-000000000006', '73666666-0000-4000-8000-000000000006', '고동욱', 'Ko DW',  'ESG Manager', 'ESG팀', 'dw.ko@eunsungmat.demo',   '+82-41-666-3006', TRUE, 'ko');

INSERT INTO supplier_risk_profiles (supplier_id, overall_risk_score, risk_level, self_reported_risk_level, is_high_risk_flag, last_risk_review_at) VALUES
('63111111-0000-4000-8000-000000000001', 16, 'low',    'low', FALSE, now() - interval '7 days'),
('63222222-0000-4000-8000-000000000002', 38, 'medium', 'low', FALSE, now() - interval '7 days'),
('63333333-0000-4000-8000-000000000003', 17, 'low',    'low', FALSE, now() - interval '7 days'),
('63444444-0000-4000-8000-000000000004', 19, 'low',    'low', FALSE, now() - interval '7 days'),
('63555555-0000-4000-8000-000000000005', 26, 'medium', 'low', FALSE, now() - interval '7 days'),
('63666666-0000-4000-8000-000000000006', 18, 'low',    'low', FALSE, now() - interval '7 days');


-- ============================================================
-- 16-7. 4차 협력사 — 신규 5개 (제련/정제, smelter)
-- ============================================================
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, ceo_name, provider_type, core_minerals, country, address, business_reg_doc_url, environmental_report_url, completeness_score, status, risk_level) VALUES
('64111111-0000-4000-8000-000000000001', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '고려제련(주)', 'Koryo Smelting Corp', 'Jang YB CEO', 'smelter', '{"Ni":99.5,"Co":99.8}'::jsonb, 'KR', '경상남도 울산시 울주군 온산읍 온산공단로 55', 's3://kira-docs/suppliers/64111111/biz_reg.pdf', NULL, 80, 'supplier_verified', 'low'),
('64222222-0000-4000-8000-000000000002', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'PT Indosel Nickel Refinery', 'PT Indosel Nickel Refinery', 'Budi Hartono CEO', 'smelter', '{"Ni":99.2}'::jsonb, 'ID', 'Sulawesi Tengah, Morowali Industrial Park', 's3://kira-docs/suppliers/64222222/biz_reg.pdf', NULL, 55, 'supplier_review', 'medium'),
('64333333-0000-4000-8000-000000000003', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'AusRef Processing Pty Ltd', 'AusRef Processing Pty Ltd', 'James Wilson CEO', 'smelter', '{"Ni":99.7}'::jsonb, 'AU', 'Western Australia, Kwinana Industrial Area', 's3://kira-docs/suppliers/64333333/biz_reg.pdf', 's3://kira-docs/suppliers/64333333/env_report.pdf', 78, 'supplier_verified', 'low'),
('64444444-0000-4000-8000-000000000004', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Zambia Copper & Cobalt Refinery', 'Zambia Copper & Cobalt Refinery', 'Emmanuel Banda CEO', 'smelter', '{"Co":85.0,"Ni":10.0}'::jsonb, 'ZM', 'Copperbelt Province, Kitwe Industrial Area', 's3://kira-docs/suppliers/64444444/biz_reg.pdf', NULL, 50, 'supplier_review', 'medium'),
('64555555-0000-4000-8000-000000000005', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Brazil Nickel Refining SA', 'Brazil Nickel Refining SA', 'Carlos Silva CEO', 'smelter', '{"Ni":99.4}'::jsonb, 'BR', 'Goiás State, Niquelândia Industrial Zone', 's3://kira-docs/suppliers/64555555/biz_reg.pdf', 's3://kira-docs/suppliers/64555555/env_report.pdf', 77, 'supplier_verified', 'low');

UPDATE suppliers SET smelter_type = 'rmi'     WHERE supplier_id IN ('64111111-0000-4000-8000-000000000001', '64333333-0000-4000-8000-000000000003', '64555555-0000-4000-8000-000000000005');
UPDATE suppliers SET smelter_type = 'private' WHERE supplier_id IN ('64222222-0000-4000-8000-000000000002', '64444444-0000-4000-8000-000000000004');

INSERT INTO supplier_factories (factory_id, supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent) VALUES
('74111111-0000-4000-8000-000000000001', '64111111-0000-4000-8000-000000000001', '온산 제련소 2호',   'Onsan Smelter No.2', 'KR', 'Onsan',    ST_SetSRID(ST_MakePoint(129.350, 35.430), 4326), 'processing', 'BOTH', '["CRMA","EU_BATTERY"]'::jsonb, 100.00),
('74222222-0000-4000-8000-000000000002', '64222222-0000-4000-8000-000000000002', 'Morowali Refinery', 'Morowali Refinery',   'ID', 'Sulawesi', ST_SetSRID(ST_MakePoint(121.640, -2.010), 4326), 'processing', 'BOTH', '["CRMA","CONFLICT_MINERALS","EUDR"]'::jsonb, 100.00),
('74333333-0000-4000-8000-000000000003', '64333333-0000-4000-8000-000000000003', 'Kwinana Ni Refinery','Kwinana Ni Refinery', 'AU', 'Western Australia', ST_SetSRID(ST_MakePoint(115.770, -32.230), 4326), 'processing', 'BOTH', '["CRMA"]'::jsonb, 100.00),
('74444444-0000-4000-8000-000000000004', '64444444-0000-4000-8000-000000000004', 'Kitwe Refinery',    'Kitwe Refinery',      'ZM', 'Copperbelt', ST_SetSRID(ST_MakePoint(28.213, -12.818), 4326), 'processing', 'BOTH', '["CONFLICT_MINERALS","CRMA"]'::jsonb, 100.00),
('74555555-0000-4000-8000-000000000005', '64555555-0000-4000-8000-000000000005', 'Niquelândia Refinery','Niquelandia Refinery','BR', 'Goias',   ST_SetSRID(ST_MakePoint(-48.460, -14.470), 4326), 'processing', 'BOTH', '["CRMA"]'::jsonb, 100.00);

INSERT INTO supplier_contacts (supplier_id, factory_id, name, name_en, role, department, email, phone, is_primary, language) VALUES
('64111111-0000-4000-8000-000000000001', '74111111-0000-4000-8000-000000000001', '장영범', '장영범', 'Compliance Manager', 'Compliance', 'jang@koryosmelt.demo', '+82-52-111-4001',  TRUE, 'ko'),
('64222222-0000-4000-8000-000000000002', '74222222-0000-4000-8000-000000000002', 'Budi Santoso', 'Budi Santoso', 'Compliance Manager', 'Compliance', 'budi@indosel.demo', '+62-21-222-4002', TRUE, 'en'),
('64333333-0000-4000-8000-000000000003', '74333333-0000-4000-8000-000000000003', 'James Wilson', 'James Wilson', 'ESG Manager', 'ESG', 'j.wilson@ausref.demo', '+61-8-333-4003',       TRUE, 'en'),
('64444444-0000-4000-8000-000000000004', '74444444-0000-4000-8000-000000000004', 'Emmanuel Banda', 'Emmanuel Banda', 'Compliance Manager', 'Compliance', 'e.banda@zamcopper.demo', '+260-212-444-4004', TRUE, 'en'),
('64555555-0000-4000-8000-000000000005', '74555555-0000-4000-8000-000000000005', 'Carlos Silva', 'Carlos Silva', 'ESG Manager', 'ESG', 'c.silva@brnickel.demo', '+55-62-555-4005',     TRUE, 'en');

INSERT INTO supplier_risk_profiles (supplier_id, overall_risk_score, risk_level, self_reported_risk_level, is_high_risk_flag, high_risk_reasons, last_risk_review_at) VALUES
('64111111-0000-4000-8000-000000000001', 12, 'low',    'low', FALSE, NULL, now() - interval '7 days'),
('64222222-0000-4000-8000-000000000002', 45, 'medium', 'low', TRUE,  '["인도네시아 니켈광 인접 산림훼손 리스크(EUDR)"]'::jsonb, now() - interval '7 days'),
('64333333-0000-4000-8000-000000000003', 10, 'low',    'low', FALSE, NULL, now() - interval '7 days'),
('64444444-0000-4000-8000-000000000004', 48, 'medium', 'low', TRUE,  '["잠비아 코퍼벨트 — DRC 인접 분쟁광물 리스크"]'::jsonb, now() - interval '7 days'),
('64555555-0000-4000-8000-000000000005', 11, 'low',    'low', FALSE, NULL, now() - interval '7 days');


-- ============================================================
-- 16-8. 5차 협력사 — 신규 5개 (광산, miner)
-- ============================================================
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, ceo_name, provider_type, country, address, business_reg_doc_url, completeness_score, status, risk_level) VALUES
('65111111-0000-4000-8000-000000000001', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Sulawesi Nickel Mining Corp', 'Sulawesi Nickel Mining Corp', 'Andi Wijaya CEO', 'miner', 'ID', 'Sulawesi Tengah, Morowali Mining District', NULL, 40, 'supplier_in_progress', 'medium'),
('65222222-0000-4000-8000-000000000002', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Weda Bay Nickel Mine', 'Weda Bay Nickel Mine', 'Liu Wei CEO', 'miner', 'ID', 'North Maluku, Weda Bay Industrial Park', NULL, 35, 'supplier_review', 'medium'),
('65333333-0000-4000-8000-000000000003', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Western Australia Nickel Mine Pty Ltd', 'Western Australia Nickel Mine Pty Ltd', 'Sarah Thompson CEO', 'miner', 'AU', 'Western Australia, Kalgoorlie Mining District', 's3://kira-docs/suppliers/65333333/biz_reg.pdf', 68, 'supplier_verified', 'low'),
('65444444-0000-4000-8000-000000000004', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Zambia Copperbelt Cobalt Mine', 'Zambia Copperbelt Cobalt Mine', 'Joseph Mwansa CEO', 'miner', 'ZM', 'Copperbelt Province, Chililabombwe Mining Zone', NULL, 30, 'supplier_in_progress', 'medium'),
('65555555-0000-4000-8000-000000000005', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Brazil Nickel Laterite Mine', 'Brazil Nickel Laterite Mine', 'Paulo Almeida CEO', 'miner', 'BR', 'Goiás State, Niquelândia Mining District', 's3://kira-docs/suppliers/65555555/biz_reg.pdf', 65, 'supplier_verified', 'low');

INSERT INTO supplier_factories (factory_id, supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent) VALUES
('75111111-0000-4000-8000-000000000001', '65111111-0000-4000-8000-000000000001', 'Sulawesi Nickel Mine',      'Sulawesi Nickel Mine',      'ID', 'Sulawesi',   ST_SetSRID(ST_MakePoint(121.700, -1.950), 4326),  'mining', 'BOTH', '["CRMA","CONFLICT_MINERALS","EUDR"]'::jsonb, 100.00),
('75222222-0000-4000-8000-000000000002', '65222222-0000-4000-8000-000000000002', 'Weda Bay Mine',             'Weda Bay Mine',             'ID', 'Halmahera',  ST_SetSRID(ST_MakePoint(127.900, -0.420), 4326),  'mining', 'BOTH', '["CRMA","EUDR"]'::jsonb, 100.00),
('75333333-0000-4000-8000-000000000003', '65333333-0000-4000-8000-000000000003', 'Kalgoorlie Nickel Mine',    'Kalgoorlie Nickel Mine',    'AU', 'Western Australia', ST_SetSRID(ST_MakePoint(121.470, -30.750), 4326), 'mining', 'BOTH', '["CRMA"]'::jsonb, 100.00),
('75444444-0000-4000-8000-000000000004', '65444444-0000-4000-8000-000000000004', 'Chililabombwe Cobalt Mine', 'Chililabombwe Cobalt Mine', 'ZM', 'Copperbelt', ST_SetSRID(ST_MakePoint(27.827, -12.368), 4326),  'mining', 'BOTH', '["CONFLICT_MINERALS","CRMA"]'::jsonb, 100.00),
('75555555-0000-4000-8000-000000000005', '65555555-0000-4000-8000-000000000005', 'Niquelândia Laterite Mine', 'Niquelandia Laterite Mine', 'BR', 'Goias',      ST_SetSRID(ST_MakePoint(-48.480, -14.500), 4326), 'mining', 'BOTH', '["CRMA"]'::jsonb, 100.00);

INSERT INTO supplier_miner_details (supplier_id, mine_name, mining_method, extraction_volume, mine_coordinates, active_period_from) VALUES
('65111111-0000-4000-8000-000000000001', 'Sulawesi Nickel Mine A',    'open_pit', 45000.00, ST_SetSRID(ST_MakePoint(121.700, -1.950), 4326),  '2020-01-01'),
('65222222-0000-4000-8000-000000000002', 'Weda Bay Nickel Mine A',    'open_pit', 60000.00, ST_SetSRID(ST_MakePoint(127.900, -0.420), 4326),  '2019-01-01'),
('65333333-0000-4000-8000-000000000003', 'Kalgoorlie Nickel Mine',    'open_pit', 38000.00, ST_SetSRID(ST_MakePoint(121.470, -30.750), 4326), '2017-01-01'),
('65444444-0000-4000-8000-000000000004', 'Chililabombwe Cobalt Mine', 'open_pit', 20000.00, ST_SetSRID(ST_MakePoint(27.827, -12.368), 4326),  '2018-01-01'),
('65555555-0000-4000-8000-000000000005', 'Niquelândia Laterite Mine', 'open_pit', 42000.00, ST_SetSRID(ST_MakePoint(-48.480, -14.500), 4326), '2016-01-01');

INSERT INTO supplier_contacts (supplier_id, factory_id, name, name_en, role, department, email, phone, is_primary, language) VALUES
('65111111-0000-4000-8000-000000000001', '75111111-0000-4000-8000-000000000001', 'Andi Wijaya',    'Andi Wijaya',    'Mine Manager', 'Operations', 'a.wijaya@sulawesinickel.demo', '+62-451-111-5001', TRUE, 'en'),
('65222222-0000-4000-8000-000000000002', '75222222-0000-4000-8000-000000000002', 'Liu Wei',        'Liu Wei',        'Mine Manager', 'Operations', 'l.wei@wedabay.demo',           '+62-921-222-5002', TRUE, 'en'),
('65333333-0000-4000-8000-000000000003', '75333333-0000-4000-8000-000000000003', 'Sarah Thompson', 'Sarah Thompson', 'Mine Manager', 'Operations', 's.thompson@wamine.demo',       '+61-8-333-5003',   TRUE, 'en'),
('65444444-0000-4000-8000-000000000004', '75444444-0000-4000-8000-000000000004', 'Joseph Mwansa',  'Joseph Mwansa',  'Mine Manager', 'Operations', 'j.mwansa@zamcobaltmine.demo',  '+260-212-444-5004',TRUE, 'en'),
('65555555-0000-4000-8000-000000000005', '75555555-0000-4000-8000-000000000005', 'Paulo Almeida',  'Paulo Almeida',  'Mine Manager', 'Operations', 'p.almeida@brnickelmine.demo',  '+55-62-555-5005',  TRUE, 'en');

INSERT INTO supplier_risk_profiles (supplier_id, overall_risk_score, risk_level, self_reported_risk_level, is_high_risk_flag, high_risk_reasons, last_risk_review_at) VALUES
('65111111-0000-4000-8000-000000000001', 42, 'medium', 'low', TRUE,  '["산림훼손 인접 채굴 지역(EUDR)"]'::jsonb, now() - interval '7 days'),
('65222222-0000-4000-8000-000000000002', 44, 'medium', 'low', TRUE,  '["산림훼손 인접 채굴 지역(EUDR)"]'::jsonb, now() - interval '7 days'),
('65333333-0000-4000-8000-000000000003', 10, 'low',    'low', FALSE, NULL, now() - interval '7 days'),
('65444444-0000-4000-8000-000000000004', 46, 'medium', 'low', TRUE,  '["DRC 접경 분쟁광물 리스크 지역"]'::jsonb, now() - interval '7 days'),
('65555555-0000-4000-8000-000000000005', 12, 'low',    'low', FALSE, NULL, now() - interval '7 days');


-- ============================================================
-- 16-9. 공급망 맵 엣지 — 신규 6개 제품 (hop0~hop5, part_id는 기존
--        NCM811 트리 재사용: Module→CAM→PRE→REF-NI→MIN-NI)
-- ============================================================

-- ⑤ BMW iX [Happy + Dual-source] — 1차: 삼보배터리(주력)+신성배터리(보조,미검증)
INSERT INTO supply_chain_map (edge_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('85555555-0000-4000-8000-000000000001', 'e5555555-0000-4000-8000-000000000005', NULL,                                     'a0000000-0000-4000-8000-000000000000', 'b1111111-0000-4000-8000-000000000001', 0, 'supplychain_confirmed', 'ERP',              'verified',   '2024-07-01', '2025-06-30'),
('85555555-0000-4000-8000-000000000002', 'e5555555-0000-4000-8000-000000000005', 'a0000000-0000-4000-8000-000000000000', '61111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000002', 1, 'supplychain_confirmed', 'ERP',              'verified',   '2024-07-01', '2025-06-30'),
('85555555-0000-4000-8000-000000000003', 'e5555555-0000-4000-8000-000000000005', 'a0000000-0000-4000-8000-000000000000', '61777777-0000-4000-8000-000000000007', 'b1111111-0000-4000-8000-000000000002', 1, 'supplychain_declared',  'SUPPLIER_DECLARED','unverified', '2024-07-01', '2025-06-30'),
('85555555-0000-4000-8000-000000000004', 'e5555555-0000-4000-8000-000000000005', '61111111-0000-4000-8000-000000000001', '62111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000006', 2, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified',   '2024-07-01', '2025-06-30'),
('85555555-0000-4000-8000-000000000005', 'e5555555-0000-4000-8000-000000000005', '62111111-0000-4000-8000-000000000001', '63111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000004', 3, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified',   '2024-07-01', '2025-06-30'),
('85555555-0000-4000-8000-000000000006', 'e5555555-0000-4000-8000-000000000005', '63111111-0000-4000-8000-000000000001', '64111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000011', 4, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified',   '2024-07-01', '2025-06-30'),
('85555555-0000-4000-8000-000000000007', 'e5555555-0000-4000-8000-000000000005', '64111111-0000-4000-8000-000000000001', '65111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000008', 5, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified',   '2024-07-01', '2025-06-30');

-- ⑥ Mercedes EQE [Happy]
INSERT INTO supply_chain_map (edge_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('86666666-0000-4000-8000-000000000001', 'e6666666-0000-4000-8000-000000000006', NULL,                                     'a0000000-0000-4000-8000-000000000000', 'b1111111-0000-4000-8000-000000000001', 0, 'supplychain_confirmed', 'ERP',              'verified',   '2024-04-01', '2025-03-31'),
('86666666-0000-4000-8000-000000000002', 'e6666666-0000-4000-8000-000000000006', 'a0000000-0000-4000-8000-000000000000', '61222222-0000-4000-8000-000000000002', 'b1111111-0000-4000-8000-000000000002', 1, 'supplychain_confirmed', 'ERP',              'verified',   '2024-04-01', '2025-03-31'),
('86666666-0000-4000-8000-000000000003', 'e6666666-0000-4000-8000-000000000006', '61222222-0000-4000-8000-000000000002', '62222222-0000-4000-8000-000000000002', 'b1111111-0000-4000-8000-000000000006', 2, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified',   '2024-04-01', '2025-03-31'),
('86666666-0000-4000-8000-000000000004', 'e6666666-0000-4000-8000-000000000006', '62222222-0000-4000-8000-000000000002', '63222222-0000-4000-8000-000000000002', 'b1111111-0000-4000-8000-000000000004', 3, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified',   '2024-04-01', '2025-03-31'),
('86666666-0000-4000-8000-000000000005', 'e6666666-0000-4000-8000-000000000006', '63222222-0000-4000-8000-000000000002', '64222222-0000-4000-8000-000000000002', 'b1111111-0000-4000-8000-000000000011', 4, 'supplychain_declared',  'SUPPLIER_DECLARED','unverified', '2024-04-01', '2025-03-31'),
('86666666-0000-4000-8000-000000000006', 'e6666666-0000-4000-8000-000000000006', '64222222-0000-4000-8000-000000000002', '65222222-0000-4000-8000-000000000002', 'b1111111-0000-4000-8000-000000000008', 5, 'supplychain_declared',  'SUPPLIER_DECLARED','unverified', '2024-04-01', '2025-03-31');

-- ⑦ Hyundai IONIQ 6 [Happy]
INSERT INTO supply_chain_map (edge_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('87777777-0000-4000-8000-000000000001', 'e7777777-0000-4000-8000-000000000007', NULL,                                     'a0000000-0000-4000-8000-000000000000', 'b1111111-0000-4000-8000-000000000001', 0, 'supplychain_confirmed', 'ERP',              'verified', '2024-01-01', '2024-12-31'),
('87777777-0000-4000-8000-000000000002', 'e7777777-0000-4000-8000-000000000007', 'a0000000-0000-4000-8000-000000000000', '61333333-0000-4000-8000-000000000003', 'b1111111-0000-4000-8000-000000000002', 1, 'supplychain_confirmed', 'ERP',              'verified', '2024-01-01', '2024-12-31'),
('87777777-0000-4000-8000-000000000003', 'e7777777-0000-4000-8000-000000000007', '61333333-0000-4000-8000-000000000003', '62333333-0000-4000-8000-000000000003', 'b1111111-0000-4000-8000-000000000006', 2, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified', '2024-01-01', '2024-12-31'),
('87777777-0000-4000-8000-000000000004', 'e7777777-0000-4000-8000-000000000007', '62333333-0000-4000-8000-000000000003', '63333333-0000-4000-8000-000000000003', 'b1111111-0000-4000-8000-000000000004', 3, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified', '2024-01-01', '2024-12-31'),
('87777777-0000-4000-8000-000000000005', 'e7777777-0000-4000-8000-000000000007', '63333333-0000-4000-8000-000000000003', '64333333-0000-4000-8000-000000000003', 'b1111111-0000-4000-8000-000000000011', 4, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified', '2024-01-01', '2024-12-31'),
('87777777-0000-4000-8000-000000000006', 'e7777777-0000-4000-8000-000000000007', '64333333-0000-4000-8000-000000000003', '65333333-0000-4000-8000-000000000003', 'b1111111-0000-4000-8000-000000000008', 5, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified', '2024-01-01', '2024-12-31');

-- ⑧ Hyundai IONIQ 5 [Sad — Zambia 코퍼벨트 분쟁광물 리스크]
INSERT INTO supply_chain_map (edge_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('88888888-0000-4000-8000-000000000001', 'e8888888-0000-4000-8000-000000000008', NULL,                                     'a0000000-0000-4000-8000-000000000000', 'b1111111-0000-4000-8000-000000000001', 0, 'supplychain_confirmed', 'ERP',              'verified',   '2024-03-01', '2025-02-28'),
('88888888-0000-4000-8000-000000000002', 'e8888888-0000-4000-8000-000000000008', 'a0000000-0000-4000-8000-000000000000', '61444444-0000-4000-8000-000000000004', 'b1111111-0000-4000-8000-000000000002', 1, 'supplychain_confirmed', 'ERP',              'verified',   '2024-03-01', '2025-02-28'),
('88888888-0000-4000-8000-000000000003', 'e8888888-0000-4000-8000-000000000008', '61444444-0000-4000-8000-000000000004', '62444444-0000-4000-8000-000000000004', 'b1111111-0000-4000-8000-000000000006', 2, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified',   '2024-03-01', '2025-02-28'),
('88888888-0000-4000-8000-000000000004', 'e8888888-0000-4000-8000-000000000008', '62444444-0000-4000-8000-000000000004', '63444444-0000-4000-8000-000000000004', 'b1111111-0000-4000-8000-000000000004', 3, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified',   '2024-03-01', '2025-02-28'),
('88888888-0000-4000-8000-000000000005', 'e8888888-0000-4000-8000-000000000008', '63444444-0000-4000-8000-000000000004', '64444444-0000-4000-8000-000000000004', 'b1111111-0000-4000-8000-000000000011', 4, 'supplychain_declared',  'SUPPLIER_DECLARED','unverified', '2024-03-01', '2025-02-28'),
('88888888-0000-4000-8000-000000000006', 'e8888888-0000-4000-8000-000000000008', '64444444-0000-4000-8000-000000000004', '65444444-0000-4000-8000-000000000004', 'b1111111-0000-4000-8000-000000000009', 5, 'supplychain_declared',  'SUPPLIER_DECLARED','unverified', '2024-03-01', '2025-02-28');

-- ⑨ Volkswagen ID.4 [Happy]
INSERT INTO supply_chain_map (edge_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('89999999-0000-4000-8000-000000000001', 'e9999999-0000-4000-8000-000000000009', NULL,                                     'a0000000-0000-4000-8000-000000000000', 'b1111111-0000-4000-8000-000000000001', 0, 'supplychain_confirmed', 'ERP',              'verified', '2024-06-01', '2024-12-31'),
('89999999-0000-4000-8000-000000000002', 'e9999999-0000-4000-8000-000000000009', 'a0000000-0000-4000-8000-000000000000', '61555555-0000-4000-8000-000000000005', 'b1111111-0000-4000-8000-000000000002', 1, 'supplychain_confirmed', 'ERP',              'verified', '2024-06-01', '2024-12-31'),
('89999999-0000-4000-8000-000000000003', 'e9999999-0000-4000-8000-000000000009', '61555555-0000-4000-8000-000000000005', '62555555-0000-4000-8000-000000000005', 'b1111111-0000-4000-8000-000000000006', 2, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified', '2024-06-01', '2024-12-31'),
('89999999-0000-4000-8000-000000000004', 'e9999999-0000-4000-8000-000000000009', '62555555-0000-4000-8000-000000000005', '63555555-0000-4000-8000-000000000005', 'b1111111-0000-4000-8000-000000000004', 3, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified', '2024-06-01', '2024-12-31'),
('89999999-0000-4000-8000-000000000005', 'e9999999-0000-4000-8000-000000000009', '63555555-0000-4000-8000-000000000005', '64555555-0000-4000-8000-000000000005', 'b1111111-0000-4000-8000-000000000011', 4, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified', '2024-06-01', '2024-12-31'),
('89999999-0000-4000-8000-000000000006', 'e9999999-0000-4000-8000-000000000009', '64555555-0000-4000-8000-000000000005', '65555555-0000-4000-8000-000000000005', 'b1111111-0000-4000-8000-000000000008', 5, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified', '2024-06-01', '2024-12-31');

-- ⑩ Volkswagen ID.7 [Gray — 4차에서 기존 Unverified Precursor Trading 재사용, 5차 없이 추적 단절]
INSERT INTO supply_chain_map (edge_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('8aaaaaaa-0000-4000-8000-000000000001', 'eaaaaaaa-0000-4000-8000-00000000000a', NULL,                                     'a0000000-0000-4000-8000-000000000000', 'b1111111-0000-4000-8000-000000000001', 0, 'supplychain_confirmed', 'ERP',              'verified',   '2025-01-01', '2025-12-31'),
('8aaaaaaa-0000-4000-8000-000000000002', 'eaaaaaaa-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-000000000000', '61666666-0000-4000-8000-000000000006', 'b1111111-0000-4000-8000-000000000002', 1, 'supplychain_confirmed', 'ERP',              'verified',   '2025-01-01', '2025-12-31'),
('8aaaaaaa-0000-4000-8000-000000000003', 'eaaaaaaa-0000-4000-8000-00000000000a', '61666666-0000-4000-8000-000000000006', '62666666-0000-4000-8000-000000000006', 'b1111111-0000-4000-8000-000000000006', 2, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified',   '2025-01-01', '2025-12-31'),
('8aaaaaaa-0000-4000-8000-000000000004', 'eaaaaaaa-0000-4000-8000-00000000000a', '62666666-0000-4000-8000-000000000006', '63666666-0000-4000-8000-000000000006', 'b1111111-0000-4000-8000-000000000004', 3, 'supplychain_confirmed', 'SUPPLIER_DECLARED','verified',   '2025-01-01', '2025-12-31'),
('8aaaaaaa-0000-4000-8000-000000000005', 'eaaaaaaa-0000-4000-8000-00000000000a', '63666666-0000-4000-8000-000000000006', 'abababab-abab-4000-8000-0000000000ab', 'b1111111-0000-4000-8000-000000000011', 4, 'supplychain_declared',  'SUPPLIER_DECLARED','unverified', '2025-01-01', '2025-12-31');

-- 공급망 맵 헤더(supply_chain_maps) 백필 + map_id 백필 (신규 6개 bom_version)
INSERT INTO supply_chain_maps (map_id, bom_version_id, product_id, status)
SELECT gen_random_uuid(), bv.bom_version_id, bv.product_id, 'completed'
FROM bom_versions bv
WHERE EXISTS (SELECT 1 FROM supply_chain_map scm WHERE scm.bom_version_id = bv.bom_version_id)
  AND NOT EXISTS (SELECT 1 FROM supply_chain_maps h WHERE h.bom_version_id = bv.bom_version_id);

UPDATE supply_chain_map scm SET map_id = h.map_id
FROM supply_chain_maps h
WHERE h.bom_version_id = scm.bom_version_id AND scm.map_id IS NULL;

-- 신규 6개 제품 전 엣지 supply_ratio (분할납품 비율 — BMW iX는 삼보 90% + 신성 10% dual-source)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit) VALUES
('85555555-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000000', 100.00,   500, 'ea'),
('85555555-0000-4000-8000-000000000002', '71111111-0000-4000-8000-000000000001',  90.00,  9450, 'ea'),
('85555555-0000-4000-8000-000000000003', '71777777-0000-4000-8000-000000000007',  10.00,  1050, 'ea'),
('85555555-0000-4000-8000-000000000004', '72111111-0000-4000-8000-000000000001', 100.00, 42000, 'kg'),
('85555555-0000-4000-8000-000000000005', '73111111-0000-4000-8000-000000000001', 100.00, 25000, 'kg'),
('85555555-0000-4000-8000-000000000006', '74111111-0000-4000-8000-000000000001', 100.00, 20000, 'kg'),
('85555555-0000-4000-8000-000000000007', '75111111-0000-4000-8000-000000000001', 100.00, 26000, 'kg'),
('86666666-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000000', 100.00,   480, 'ea'),
('86666666-0000-4000-8000-000000000002', '71222222-0000-4000-8000-000000000002', 100.00,  9200, 'ea'),
('86666666-0000-4000-8000-000000000003', '72222222-0000-4000-8000-000000000002', 100.00, 38000, 'kg'),
('86666666-0000-4000-8000-000000000004', '73222222-0000-4000-8000-000000000002', 100.00, 23000, 'kg'),
('86666666-0000-4000-8000-000000000005', '74222222-0000-4000-8000-000000000002', 100.00, 18500, 'kg'),
('86666666-0000-4000-8000-000000000006', '75222222-0000-4000-8000-000000000002', 100.00, 24000, 'kg'),
('87777777-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000000', 100.00,   460, 'ea'),
('87777777-0000-4000-8000-000000000002', '71333333-0000-4000-8000-000000000003', 100.00,  9500, 'ea'),
('87777777-0000-4000-8000-000000000003', '72333333-0000-4000-8000-000000000003', 100.00, 40000, 'kg'),
('87777777-0000-4000-8000-000000000004', '73333333-0000-4000-8000-000000000003', 100.00, 24000, 'kg'),
('87777777-0000-4000-8000-000000000005', '74333333-0000-4000-8000-000000000003', 100.00, 19000, 'kg'),
('87777777-0000-4000-8000-000000000006', '75333333-0000-4000-8000-000000000003', 100.00, 25000, 'kg'),
('88888888-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000000', 100.00,   420, 'ea'),
('88888888-0000-4000-8000-000000000002', '71444444-0000-4000-8000-000000000004', 100.00,  8500, 'ea'),
('88888888-0000-4000-8000-000000000003', '72444444-0000-4000-8000-000000000004', 100.00, 36000, 'kg'),
('88888888-0000-4000-8000-000000000004', '73444444-0000-4000-8000-000000000004', 100.00, 21000, 'kg'),
('88888888-0000-4000-8000-000000000005', '74444444-0000-4000-8000-000000000004', 100.00, 17000, 'kg'),
('88888888-0000-4000-8000-000000000006', '75444444-0000-4000-8000-000000000004', 100.00, 22000, 'kg'),
('89999999-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000000', 100.00,   410, 'ea'),
('89999999-0000-4000-8000-000000000002', '71555555-0000-4000-8000-000000000005', 100.00,  8800, 'ea'),
('89999999-0000-4000-8000-000000000003', '72555555-0000-4000-8000-000000000005', 100.00, 37000, 'kg'),
('89999999-0000-4000-8000-000000000004', '73555555-0000-4000-8000-000000000005', 100.00, 22000, 'kg'),
('89999999-0000-4000-8000-000000000005', '74555555-0000-4000-8000-000000000005', 100.00, 17500, 'kg'),
('89999999-0000-4000-8000-000000000006', '75555555-0000-4000-8000-000000000005', 100.00, 23000, 'kg'),
('8aaaaaaa-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000000', 100.00,   490, 'ea'),
('8aaaaaaa-0000-4000-8000-000000000002', '71666666-0000-4000-8000-000000000006', 100.00, 10000, 'ea'),
('8aaaaaaa-0000-4000-8000-000000000003', '72666666-0000-4000-8000-000000000006', 100.00, 42000, 'kg'),
('8aaaaaaa-0000-4000-8000-000000000004', '73666666-0000-4000-8000-000000000006', 100.00, 25000, 'kg');
-- 8aaaaaaa-...005(hop4, Unverified Trader): factory 미확인 — supply_ratio 의도적 미입력 (Gray 시나리오)

-- ============================================================
-- 16-SUMMARY (검증용)
-- ============================================================
-- Ingest 묶음(bom_version):  기존 5 + 신규 6 = 11개
-- 1차 협력사(hop1 최소차수): 기존 3 + 신규 7 = 10개 (신성배터리=이중소싱 보조사)
-- 2차 협력사(hop2 최소차수): 기존 3 + 신규 6 =  9개
-- 3차 협력사(hop3 최소차수): 기존 2 + 신규 6 =  8개
-- 4차 협력사(hop4 최소차수): 기존 2 + 신규 5 =  7개 (VW ID.7은 기존 Unverified Trader 재사용)
-- 5차 협력사(hop5 최소차수): 기존 1 + 신규 5 =  6개 (VW ID.7은 Gray 시나리오로 5차 없음)


-- ============================================================
-- 17. VW ID.7 — 완료 상태 → 미완료(building)로 되돌림
-- ============================================================
-- 나머지 신규 5개 제품(BMW iX/EQE/IONIQ6/IONIQ5/ID.4)은 Happy 시나리오로 완료 유지.
-- VW ID.7만 STEP2~5를 직접 밟아 워크플로우를 검증할 수 있도록 미검증 상태로 되돌린다.
UPDATE supply_chain_maps SET status = 'building', completed_by = NULL, completed_at = NULL
WHERE bom_version_id = 'eaaaaaaa-0000-4000-8000-00000000000a';

UPDATE supply_chain_map SET verification_status = 'unverified'
WHERE bom_version_id = 'eaaaaaaa-0000-4000-8000-00000000000a';


-- ============================================================
-- 18. 신규 제품 6개 — bom_items (MBOM 트리 채우기)
-- ============================================================
-- 공급망 맵 엣지가 쓰는 part 체인(Module→CAM→PRE→REF-NI→MIN-NI)과 동일 품목으로 구성.
-- direct_material_cost는 parts.unit_price 값을 그대로 사용(기존 iX3/i4 패턴과 동일).
-- VW ID.7(eaaaaaaa)은 4차에서 Unverified Trader로 끊기는 Gray 시나리오라 MIN-NI(5차) 품목 제외.

-- ⑤ BMW iX (e5555555)
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, direct_material_cost, origin_country, source_system, external_id) VALUES
('e5555555-0000-4000-8000-000000000005', 'b1111111-0000-4000-8000-000000000002', 95, 'ea', 45.00, 400.0000, 'KR', 'ERP_PLM', 'ERP-BI-IX-MOD'),
('e5555555-0000-4000-8000-000000000005', 'b1111111-0000-4000-8000-000000000006', 38, 'kg', 20.00,  90.0000, 'KR', 'ERP_PLM', 'ERP-BI-IX-CAM'),
('e5555555-0000-4000-8000-000000000005', 'b1111111-0000-4000-8000-000000000004', 24, 'kg', 15.00,  40.0000, 'KR', 'ERP_PLM', 'ERP-BI-IX-PRE'),
('e5555555-0000-4000-8000-000000000005', 'b1111111-0000-4000-8000-000000000011', 18, 'kg', 12.00,  22.0000, 'KR', 'ERP_PLM', 'ERP-BI-IX-REFNI'),
('e5555555-0000-4000-8000-000000000005', 'b1111111-0000-4000-8000-000000000008', 22, 'kg',  8.00,  18.0000, 'ID', 'ERP_PLM', 'ERP-BI-IX-NI');

-- ⑥ Mercedes EQE (e6666666)
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, direct_material_cost, origin_country, source_system, external_id) VALUES
('e6666666-0000-4000-8000-000000000006', 'b1111111-0000-4000-8000-000000000002', 90, 'ea', 45.00, 400.0000, 'KR', 'ERP_PLM', 'ERP-BI-EQE-MOD'),
('e6666666-0000-4000-8000-000000000006', 'b1111111-0000-4000-8000-000000000006', 36, 'kg', 20.00,  90.0000, 'KR', 'ERP_PLM', 'ERP-BI-EQE-CAM'),
('e6666666-0000-4000-8000-000000000006', 'b1111111-0000-4000-8000-000000000004', 23, 'kg', 15.00,  40.0000, 'KR', 'ERP_PLM', 'ERP-BI-EQE-PRE'),
('e6666666-0000-4000-8000-000000000006', 'b1111111-0000-4000-8000-000000000011', 17, 'kg', 12.00,  22.0000, 'ID', 'ERP_PLM', 'ERP-BI-EQE-REFNI'),
('e6666666-0000-4000-8000-000000000006', 'b1111111-0000-4000-8000-000000000008', 21, 'kg',  8.00,  18.0000, 'ID', 'ERP_PLM', 'ERP-BI-EQE-NI');

-- ⑦ Hyundai IONIQ 6 (e7777777)
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, direct_material_cost, origin_country, source_system, external_id) VALUES
('e7777777-0000-4000-8000-000000000007', 'b1111111-0000-4000-8000-000000000002', 88, 'ea', 45.00, 400.0000, 'KR', 'ERP_PLM', 'ERP-BI-I6-MOD'),
('e7777777-0000-4000-8000-000000000007', 'b1111111-0000-4000-8000-000000000006', 35, 'kg', 20.00,  90.0000, 'KR', 'ERP_PLM', 'ERP-BI-I6-CAM'),
('e7777777-0000-4000-8000-000000000007', 'b1111111-0000-4000-8000-000000000004', 22, 'kg', 15.00,  40.0000, 'KR', 'ERP_PLM', 'ERP-BI-I6-PRE'),
('e7777777-0000-4000-8000-000000000007', 'b1111111-0000-4000-8000-000000000011', 17, 'kg', 12.00,  22.0000, 'AU', 'ERP_PLM', 'ERP-BI-I6-REFNI'),
('e7777777-0000-4000-8000-000000000007', 'b1111111-0000-4000-8000-000000000008', 21, 'kg',  8.00,  18.0000, 'AU', 'ERP_PLM', 'ERP-BI-I6-NI');

-- ⑧ Hyundai IONIQ 5 (e8888888)
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, direct_material_cost, origin_country, source_system, external_id) VALUES
('e8888888-0000-4000-8000-000000000008', 'b1111111-0000-4000-8000-000000000002', 78, 'ea', 45.00, 400.0000, 'KR', 'ERP_PLM', 'ERP-BI-I5-MOD'),
('e8888888-0000-4000-8000-000000000008', 'b1111111-0000-4000-8000-000000000006', 31, 'kg', 20.00,  90.0000, 'KR', 'ERP_PLM', 'ERP-BI-I5-CAM'),
('e8888888-0000-4000-8000-000000000008', 'b1111111-0000-4000-8000-000000000004', 20, 'kg', 15.00,  40.0000, 'KR', 'ERP_PLM', 'ERP-BI-I5-PRE'),
('e8888888-0000-4000-8000-000000000008', 'b1111111-0000-4000-8000-000000000011', 15, 'kg', 12.00,  22.0000, 'ZM', 'ERP_PLM', 'ERP-BI-I5-REFNI'),
('e8888888-0000-4000-8000-000000000008', 'b1111111-0000-4000-8000-000000000008', 18, 'kg',  8.00,  18.0000, 'ZM', 'ERP_PLM', 'ERP-BI-I5-NI');

-- ⑨ Volkswagen ID.4 (e9999999)
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, direct_material_cost, origin_country, source_system, external_id) VALUES
('e9999999-0000-4000-8000-000000000009', 'b1111111-0000-4000-8000-000000000002', 76, 'ea', 45.00, 400.0000, 'KR', 'ERP_PLM', 'ERP-BI-ID4-MOD'),
('e9999999-0000-4000-8000-000000000009', 'b1111111-0000-4000-8000-000000000006', 30, 'kg', 20.00,  90.0000, 'KR', 'ERP_PLM', 'ERP-BI-ID4-CAM'),
('e9999999-0000-4000-8000-000000000009', 'b1111111-0000-4000-8000-000000000004', 19, 'kg', 15.00,  40.0000, 'KR', 'ERP_PLM', 'ERP-BI-ID4-PRE'),
('e9999999-0000-4000-8000-000000000009', 'b1111111-0000-4000-8000-000000000011', 15, 'kg', 12.00,  22.0000, 'BR', 'ERP_PLM', 'ERP-BI-ID4-REFNI'),
('e9999999-0000-4000-8000-000000000009', 'b1111111-0000-4000-8000-000000000008', 18, 'kg',  8.00,  18.0000, 'BR', 'ERP_PLM', 'ERP-BI-ID4-NI');

-- ⑩ Volkswagen ID.7 (eaaaaaaa) — Gray: 4차(Unverified Trader)에서 끊김, MIN-NI(5차) 품목 없음
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, direct_material_cost, origin_country, source_system, external_id) VALUES
('eaaaaaaa-0000-4000-8000-00000000000a', 'b1111111-0000-4000-8000-000000000002', 102, 'ea', 50.00, 400.0000, 'KR', 'ERP_PLM', 'ERP-BI-ID7-MOD'),
('eaaaaaaa-0000-4000-8000-00000000000a', 'b1111111-0000-4000-8000-000000000006', 41,  'kg', 22.00,  90.0000, 'KR', 'ERP_PLM', 'ERP-BI-ID7-CAM'),
('eaaaaaaa-0000-4000-8000-00000000000a', 'b1111111-0000-4000-8000-000000000004', 26,  'kg', 16.00,  40.0000, 'KR', 'ERP_PLM', 'ERP-BI-ID7-PRE'),
('eaaaaaaa-0000-4000-8000-00000000000a', 'b1111111-0000-4000-8000-000000000011', 20,  'kg', 12.00,  22.0000, NULL, 'ERP_PLM', 'ERP-BI-ID7-REFNI');


-- ============================================================
-- 19. 기존(레거시) 협력사 11개 — 기준정보·맵정보 상세 백필
-- ============================================================
-- 대상: 4대 시나리오(iX3/i4/GLC/EQS)에 이미 쓰이던 원래 협력사들.
-- [의도적 예외 — 손대지 않음]
--   · Global Mining Corp(a5555555): 위반(violation) 노드. 서류·핵심광물 미제출 상태가
--     Sad 시나리오(위반 판정)의 서사 그 자체 — 채우면 오히려 시나리오가 깨짐.
--   · Unverified Precursor Trading(abababab): Gray 시나리오의 "미확인 트레이더".
--     원산지·서류 불명이 이름 그대로의 의미 — 공장·서류 미보유가 정상.
--   · 한양셀 core_minerals: fresh-seed에서 빈칸이던 것 → 19-1에서 peer 셀과 동일 NCM811로 채움(아래).
-- ============================================================

-- 19-1. 기준정보 백필 (사업자등록번호/주소/서류 URL)
UPDATE suppliers SET business_reg_no = '101-86-40001', address = '경상북도 포항시 남구 오천읍 포항산단로 55',
  -- [fresh-seed] 최상위 셀(한양셀) 회사 기본값 채움 — 마스터폼 미입력 상태에서 소재구성이 빈칸이던 문제 정정.
  --   다른 셀(우진셀·우진배터리)과 동일 NCM811 조성. 제품별 상이값은 supply_chain_map 엣지 override가 담당.
  core_minerals = '{"Li":7.0,"Ni":80.0,"Co":10.0,"Mn":10.0}'::jsonb,
  business_reg_doc_url = 's3://kira-docs/suppliers/a1111111/biz_reg.pdf',
  environmental_report_url = 's3://kira-docs/suppliers/a1111111/env_report.pdf',
  self_assessment_doc_url = 's3://kira-docs/suppliers/a1111111/self_assess.pdf'
WHERE supplier_id = 'a1111111-1111-4000-8000-000000000001';

-- [fresh-seed] 원청(KIRA, 완제품 팩) 회사값 채움 — 고객사 데이터 다운로드(DPP/엑셀)에 완제품 핵심광물로 들어감.
UPDATE suppliers SET core_minerals = '{"Li":7.0,"Ni":80.0,"Co":10.0,"Mn":10.0}'::jsonb
WHERE supplier_id = 'a0000000-0000-4000-8000-000000000000';

UPDATE suppliers SET business_reg_no = '102-86-40002', address = '울산광역시 울주군 온산읍 산업로 700',
  core_minerals = '{"Li":7.0,"Ni":80.0,"Co":10.0,"Mn":10.0}'::jsonb,
  business_reg_doc_url = 's3://kira-docs/suppliers/a7777777/biz_reg.pdf',
  environmental_report_url = 's3://kira-docs/suppliers/a7777777/env_report.pdf',
  self_assessment_doc_url = 's3://kira-docs/suppliers/a7777777/self_assess.pdf'
WHERE supplier_id = 'a7777777-7777-4000-8000-000000000007';

UPDATE suppliers SET business_reg_no = '103-86-40003', address = '충청북도 청주시 흥덕구 오송읍 오송생명2로 25',
  core_minerals = '{"Li":7.0,"Ni":80.0,"Co":10.0,"Mn":10.0}'::jsonb,
  business_reg_doc_url = 's3://kira-docs/suppliers/a8888888/biz_reg.pdf',
  environmental_report_url = 's3://kira-docs/suppliers/a8888888/env_report.pdf',
  self_assessment_doc_url = 's3://kira-docs/suppliers/a8888888/self_assess.pdf'
WHERE supplier_id = 'a8888888-8888-4000-8000-000000000008';

UPDATE suppliers SET business_reg_no = '104-86-40004', address = '충청남도 천안시 서북구 성환읍 성환산단로 10',
  core_minerals = '{"Ni":56.0,"Co":8.0,"Mn":6.0}'::jsonb,
  business_reg_doc_url = 's3://kira-docs/suppliers/a2222222/biz_reg.pdf',
  environmental_report_url = 's3://kira-docs/suppliers/a2222222/env_report.pdf'
WHERE supplier_id = 'a2222222-2222-4000-8000-000000000002';

UPDATE suppliers SET business_reg_no = '105-86-40005', address = '전라남도 광양시 광양읍 광양산단로 18',
  core_minerals = '{"Ni":50.0,"Co":10.0,"Mn":10.0}'::jsonb,
  business_reg_doc_url = 's3://kira-docs/suppliers/a6666666/biz_reg.pdf',
  environmental_report_url = 's3://kira-docs/suppliers/a6666666/env_report.pdf'
WHERE supplier_id = 'a6666666-6666-4000-8000-000000000006';

UPDATE suppliers SET address = 'Urumqi, Xinjiang Uyghur Autonomous Region, China',
  core_minerals = '{"Ni":98.0}'::jsonb,
  business_reg_doc_url = 's3://kira-docs/suppliers/acacacac/biz_reg.pdf'
WHERE supplier_id = 'acacacac-acac-4000-8000-0000000000ac';

UPDATE suppliers SET business_reg_no = '106-86-40006', address = '경상남도 울산시 울주군 온산읍 온산공단로 60',
  core_minerals = '{"Ni":99.3,"Co":99.5}'::jsonb,
  business_reg_doc_url = 's3://kira-docs/suppliers/aaaaaaaa/biz_reg.pdf',
  environmental_report_url = 's3://kira-docs/suppliers/aaaaaaaa/env_report.pdf'
WHERE supplier_id = 'aaaaaaaa-aaaa-4000-8000-00000000000a';

UPDATE suppliers SET business_reg_no = 'CL-RUT-770511', address = 'Antofagasta Region, Salar de Atacama Industrial Zone, Chile',
  core_minerals = '{"Li":2.8}'::jsonb,   -- 원광 Li 함량(순도 99 아님). 광산 회사값=원광등급, supply_chain_map 엣지값(Li 2.8)과 일치.
  business_reg_doc_url = 's3://kira-docs/suppliers/a9999999/biz_reg.pdf'
WHERE supplier_id = 'a9999999-9999-4000-8000-000000000009';

UPDATE suppliers SET business_reg_no = 'AU-ABN-51824753556', address = 'Western Australia, Greenbushes Mining District, Australia',
  core_minerals = '{"Li":2.8}'::jsonb,   -- 원광 Li 함량(스포듀민 정광 ~6% Li2O 환산). 순도 99 아님 — 엣지값과 일치.
  business_reg_doc_url = 's3://kira-docs/suppliers/a3333333/biz_reg.pdf'
WHERE supplier_id = 'a3333333-3333-4000-8000-000000000003';

-- 19-2. 1차 협력사 PIC 3명 채우기 (한양셀: 기존 1명 + 신규 2명 / 우진배터리·우진셀: 신규 3명씩)
INSERT INTO supplier_contacts (supplier_id, factory_id, name, name_en, role, department, email, phone, is_primary, language) VALUES
('a1111111-1111-4000-8000-000000000001', 'f1111111-0000-4000-8000-000000000001', '박서준', 'Park SJ', 'Quality Manager', '품질관리팀', 'sj.park@hanyang.demo', '+82-54-000-0002', FALSE, 'ko'),
('a1111111-1111-4000-8000-000000000001', 'f1111111-0000-4000-8000-000000000001', '최유리', 'Choi YR', 'Compliance Officer', '법무팀', 'yr.choi@hanyang.demo', '+82-54-000-0003', FALSE, 'ko'),
('a7777777-7777-4000-8000-000000000007', 'f7777777-0000-4000-8000-000000000007', '박준영', 'Park JY', 'ESG Manager', 'ESG팀', 'jy.park@woojinbattery.demo', '+82-52-000-0011', TRUE,  'ko'),
('a7777777-7777-4000-8000-000000000007', 'f7777777-0000-4000-8000-000000000007', '이하늘', 'Lee HN', 'Plant Manager', '생산기술팀', 'hn.lee@woojinbattery.demo', '+82-52-000-0012', FALSE, 'ko'),
('a7777777-7777-4000-8000-000000000007', 'f7777777-0000-4000-8000-000000000007', '정민수', 'Jung MS', 'Safety Manager', '안전환경팀', 'ms.jung@woojinbattery.demo', '+82-52-000-0013', FALSE, 'ko'),
('a8888888-8888-4000-8000-000000000008', 'f8888888-0000-4000-8000-000000000008', '한지원', 'Han JW', 'ESG Officer', 'ESG팀', 'jw.han@woojincell.demo', '+82-43-000-0021', TRUE,  'ko'),
('a8888888-8888-4000-8000-000000000008', 'f8888888-0000-4000-8000-000000000008', '오세훈', 'Oh SH', 'Purchasing Manager', '구매팀', 'sh.oh@woojincell.demo', '+82-43-000-0022', FALSE, 'ko'),
('a8888888-8888-4000-8000-000000000008', 'f8888888-0000-4000-8000-000000000008', '신아영', 'Shin AY', 'R&D Manager', '연구개발팀', 'ay.shin@woojincell.demo', '+82-43-000-0023', FALSE, 'ko'),
-- 19-3. 2차~5차 협력사 PIC 1명씩 (GlobalMining·Unverified Trader 제외)
('a2222222-2222-4000-8000-000000000002', 'f2222222-0000-4000-8000-000000000002', '최도윤', 'Choi DY', 'ESG Manager', 'ESG팀', 'dy.choi@dongsungmat.demo', '+82-41-000-0031', TRUE, 'ko'),
('a6666666-6666-4000-8000-000000000006', 'f6666666-0000-4000-8000-000000000006', '정하율', 'Jung HY', 'ESG Officer', 'ESG팀', 'hy.jung@cheongjeongpre.demo', '+82-61-000-0041', TRUE, 'ko'),
('acacacac-acac-4000-8000-0000000000ac', 'facacaca-0000-4000-8000-0000000000ac', 'Wei Chen', 'Wei Chen', 'Compliance', 'Compliance', 'w.chen@xjrefinery.demo', '+86-991-000-0051', TRUE, 'en'),
('aaaaaaaa-aaaa-4000-8000-00000000000a', 'faaaaaaa-0000-4000-8000-00000000000a', '윤성민', 'Yoon SM', 'Compliance Manager', 'Compliance', 'sm.yoon@hanjungref.demo', '+82-52-000-0061', TRUE, 'ko'),
('a9999999-9999-4000-8000-000000000009', 'f9999999-0000-4000-8000-000000000009', 'Diego Fernandez', 'Diego Fernandez', 'Mine Manager', 'Operations', 'd.fernandez@chilelithium.demo', '+56-55-000-0071', TRUE, 'en'),
('a3333333-3333-4000-8000-000000000003', 'f3333333-0000-4000-8000-000000000003', 'Emma Clarke', 'Emma Clarke', 'Mine Manager', 'Operations', 'e.clarke@auslithium.demo', '+61-8-000-0081', TRUE, 'en');

-- 19-4. 제조사 상세(탄소집약도/에너지원) — 누락분(우진셀·청정전구체)만 추가
INSERT INTO supplier_manufacturer_details (supplier_id, manufacturing_process, energy_source, capacity, carbon_intensity) VALUES
('a8888888-8888-4000-8000-000000000008', 'NCM811 Cell Assembly', 'mixed', '6GWh/yr', 2.6800),
('a6666666-6666-4000-8000-000000000006', 'NCM Precursor Co-precipitation', 'renewable', '10kt/yr', 3.4500);

-- 19-5. 공장 탄소발자국 선언 — 누락분(우진셀·청정전구체·한중제련·신장니켈제련) 추가
INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source) VALUES
('f8888888-0000-4000-8000-000000000008', 2.6800, 'PEF', '2025-06-01', '2025-06-01', 'supplier_declared'),
('f6666666-0000-4000-8000-000000000006', 3.4500, 'PEF', '2025-01-01', '2025-01-01', 'supplier_declared'),
('faaaaaaa-0000-4000-8000-00000000000a', 2.9000, 'PEF', '2025-01-01', '2025-01-01', 'third_party_verified'),
('facacaca-0000-4000-8000-0000000000ac', 5.2000, 'PEF', '2024-06-01', '2024-06-01', 'supplier_declared');


-- ============================================================
-- 20. 공장 담당자(factory_manager_*) 백필
-- ============================================================
-- [의존] supplier_factories.factory_manager_name/role/phone/email —
--   feature/eunjin(65a00e2 "공장 단위 담당자 필드 추가")에서 신설된 컬럼.
--   이 seed는 그 스키마 병합을 전제로 한다 — 병합 전 단독 실행 시 컬럼 없음 에러 발생.
-- 이미 seed된 supplier_contacts(협력사 PIC) 중 공장에 연결된 대표(또는 최초) 담당자를
-- factory_manager_*에도 그대로 반영 — 새 인물을 만들지 않고 기존 데이터를 재사용.
UPDATE supplier_factories sf
SET factory_manager_name  = c.name,
    factory_manager_role  = c.role,
    factory_manager_phone = c.phone,
    factory_manager_email = c.email
FROM (
  SELECT DISTINCT ON (factory_id) factory_id, name, role, phone, email
  FROM supplier_contacts
  WHERE factory_id IS NOT NULL
  ORDER BY factory_id, is_primary DESC, created_at ASC
) c
WHERE sf.factory_id = c.factory_id
  AND sf.factory_manager_name IS NULL;


-- ============================================================
-- 21. 5차 협력사(광산) 5곳 — 핵심광물 누락분 채우기
-- ============================================================
-- 제련소(정제 후 99%대)와 구분해 원광 실제 품위에 가까운 수치로 반영
-- (니켈 라테라이트 1~2%대, 코발트광 2~3%대).
-- GlobalMining Corp·Unverified Precursor Trading·신성배터리(주)는 각각 위반/Gray/온보딩초기
-- 시나리오상 의도적으로 비워둔 것이라 대상에서 제외.
UPDATE suppliers SET core_minerals = '{"Ni":1.8}'::jsonb WHERE supplier_id = '65111111-0000-4000-8000-000000000001';
UPDATE suppliers SET core_minerals = '{"Ni":1.6}'::jsonb WHERE supplier_id = '65222222-0000-4000-8000-000000000002';
UPDATE suppliers SET core_minerals = '{"Ni":2.1}'::jsonb WHERE supplier_id = '65333333-0000-4000-8000-000000000003';
UPDATE suppliers SET core_minerals = '{"Co":2.5}'::jsonb WHERE supplier_id = '65444444-0000-4000-8000-000000000004';
UPDATE suppliers SET core_minerals = '{"Ni":1.4}'::jsonb WHERE supplier_id = '65555555-0000-4000-8000-000000000005';


-- ============================================================
-- 22. PM 테스트용 — 빈 협력사 10개 + 다공장(2~3개) 협력사 3곳
-- ============================================================

-- 22-1. PM님이 마스터폼에서 직접 소재·공장·규제 정보를 입력해볼 빈 협력사 10개.
--   일부러 core_minerals/공장/담당자/서류 전부 비워둠 — 신규 온보딩 입력 흐름 테스트용.
--   provider_type을 4종류로 섞어 마스터폼의 유형별 입력 필드 차이도 확인 가능하게 함.
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, provider_type, completeness_score, status, risk_level) VALUES
('71000001-0000-4000-8000-000000000001', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'PM테스트협력사01(제조사)', 'PM Test Supplier 01', 'manufacturer', 0, 'supplier_pending', 'low'),
('71000002-0000-4000-8000-000000000002', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'PM테스트협력사02(제조사)', 'PM Test Supplier 02', 'manufacturer', 0, 'supplier_pending', 'low'),
('71000003-0000-4000-8000-000000000003', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'PM테스트협력사03(제조사)', 'PM Test Supplier 03', 'manufacturer', 0, 'supplier_pending', 'low'),
('71000004-0000-4000-8000-000000000004', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'PM테스트협력사04(제조사)', 'PM Test Supplier 04', 'manufacturer', 0, 'supplier_pending', 'low'),
('71000005-0000-4000-8000-000000000005', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'PM테스트협력사05(광산)', 'PM Test Supplier 05', 'miner', 0, 'supplier_pending', 'low'),
('71000006-0000-4000-8000-000000000006', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'PM테스트협력사06(광산)', 'PM Test Supplier 06', 'miner', 0, 'supplier_pending', 'low'),
('71000007-0000-4000-8000-000000000007', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'PM테스트협력사07(제련소)', 'PM Test Supplier 07', 'smelter', 0, 'supplier_pending', 'low'),
('71000008-0000-4000-8000-000000000008', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'PM테스트협력사08(제련소)', 'PM Test Supplier 08', 'smelter', 0, 'supplier_pending', 'low'),
('71000009-0000-4000-8000-000000000009', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'PM테스트협력사09(유통)', 'PM Test Supplier 09', 'trader', 0, 'supplier_pending', 'low'),
('7100000a-0000-4000-8000-00000000000a', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'PM테스트협력사10(유통)', 'PM Test Supplier 10', 'trader', 0, 'supplier_pending', 'low');

-- 22-2. 다공장(2~3개) 협력사 3곳 — 기존 단일공장 100% 비율을 여러 공장으로 분할.
--   하나에너지셀(2개) / 성진셀(3개) / 한독배터리(2개). 전부 Happy(완료) 시나리오 소속이라
--   VW ID.7(Gray 테스트베드)엔 영향 없음.

-- 하나에너지셀(주) 2번째 공장 — 세종
INSERT INTO supplier_factories (factory_id, supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
VALUES ('71222223-0000-4000-8000-000000000002', '61222222-0000-4000-8000-000000000002', '세종 제2공장', 'Sejong Plant 2', 'KR', 'Sejong', ST_SetSRID(ST_MakePoint(127.290, 36.480), 4326), 'production', 'EU', '["EU_BATTERY","EU_BATTERY_ART7"]'::jsonb, 40.00, '오민준', 'Plant Manager', '+82-43-222-0002', 'mj.oh@hanaenergy.demo')
ON CONFLICT (factory_id) DO NOTHING;

-- 성진셀(주) 2·3번째 공장 — 김해·밀양
INSERT INTO supplier_factories (factory_id, supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
VALUES
('71333334-0000-4000-8000-000000000003', '61333333-0000-4000-8000-000000000003', '김해 제2공장', 'Gimhae Plant 2', 'KR', 'Gimhae',  ST_SetSRID(ST_MakePoint(128.889, 35.228), 4326), 'production', 'EU', '["EU_BATTERY","EU_BATTERY_ART7"]'::jsonb, 30.00, '정유진', 'Purchasing Manager', '+82-55-333-0002', 'yj.jung@sungjincell.demo'),
('71333335-0000-4000-8000-000000000004', '61333333-0000-4000-8000-000000000003', '밀양 제3공장', 'Miryang Plant 3', 'KR', 'Miryang', ST_SetSRID(ST_MakePoint(128.746, 35.503), 4326), 'production', 'EU', '["EU_BATTERY"]'::jsonb, 20.00, '백승호', 'R&D Manager', '+82-55-333-0003', 'sh.baek@sungjincell.demo')
ON CONFLICT (factory_id) DO NOTHING;

-- 한독배터리(주) 2번째 공장 — 대구
INSERT INTO supplier_factories (factory_id, supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
VALUES ('71555556-0000-4000-8000-000000000005', '61555555-0000-4000-8000-000000000005', '대구 제2공장', 'Daegu Plant 2', 'KR', 'Daegu', ST_SetSRID(ST_MakePoint(128.601, 35.871), 4326), 'production', 'BOTH', '["EU_BATTERY","EU_BATTERY_ART7"]'::jsonb, 30.00, '박혜진', 'Supply Chain Mgr', '+82-54-555-0003', 'hj.park@handokbattery.demo')
ON CONFLICT (factory_id) DO NOTHING;

-- 기존 공장의 supply_ratio_percent·공급비율을 분할 비율로 조정(기존 100% → 신규 공장분 반영).
UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '71222222-0000-4000-8000-000000000002';
UPDATE supplier_factories SET supply_ratio_percent = 50.00 WHERE factory_id = '71333333-0000-4000-8000-000000000003';
UPDATE supplier_factories SET supply_ratio_percent = 70.00 WHERE factory_id = '71555555-0000-4000-8000-000000000005';

-- supply_ratio(엣지별 공급비율) — 기존 100% 단일행을 공장별로 분할.
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 5520 WHERE edge_id = '86666666-0000-4000-8000-000000000002' AND factory_id = '71222222-0000-4000-8000-000000000002';
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '86666666-0000-4000-8000-000000000002', '71222223-0000-4000-8000-000000000002', 40.00, 3680, 'ea'
WHERE NOT EXISTS (SELECT 1 FROM supply_ratio WHERE edge_id = '86666666-0000-4000-8000-000000000002' AND factory_id = '71222223-0000-4000-8000-000000000002');

UPDATE supply_ratio SET ratio_percentage = 50.00, volume = 4750 WHERE edge_id = '87777777-0000-4000-8000-000000000002' AND factory_id = '71333333-0000-4000-8000-000000000003';
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT * FROM (VALUES
  ('87777777-0000-4000-8000-000000000002'::uuid, '71333334-0000-4000-8000-000000000003'::uuid, 30.00::numeric, 2850::numeric, 'ea'),
  ('87777777-0000-4000-8000-000000000002'::uuid, '71333335-0000-4000-8000-000000000004'::uuid, 20.00::numeric, 1900::numeric, 'ea')
) AS v(edge_id, factory_id, ratio_percentage, volume, unit)
WHERE NOT EXISTS (SELECT 1 FROM supply_ratio sr WHERE sr.edge_id = v.edge_id AND sr.factory_id = v.factory_id);

UPDATE supply_ratio SET ratio_percentage = 70.00, volume = 6160 WHERE edge_id = '89999999-0000-4000-8000-000000000002' AND factory_id = '71555555-0000-4000-8000-000000000005';
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '89999999-0000-4000-8000-000000000002', '71555556-0000-4000-8000-000000000005', 30.00, 2640, 'ea'
WHERE NOT EXISTS (SELECT 1 FROM supply_ratio WHERE edge_id = '89999999-0000-4000-8000-000000000002' AND factory_id = '71555556-0000-4000-8000-000000000005');

-- 신규 공장들도 탄소발자국 선언(규제 정보) 반영 — PM 요청("규제 들어와있어야") 충족.
INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
SELECT * FROM (VALUES
  ('71222223-0000-4000-8000-000000000002'::uuid, 2.4500::numeric, 'PEF', '2024-04-01'::date, '2024-04-01'::date, 'supplier_declared'),
  ('71333334-0000-4000-8000-000000000003'::uuid, 2.9500::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),
  ('71333335-0000-4000-8000-000000000004'::uuid, 3.1000::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),
  ('71555556-0000-4000-8000-000000000005'::uuid, 2.3000::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'third_party_verified')
) AS v(factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
WHERE NOT EXISTS (SELECT 1 FROM factory_carbon_declarations WHERE factory_id = v.factory_id);


-- ============================================================
-- 23. 나머지 협력사(예외 4곳 제외) 규제 정보(탄소발자국 선언) 전량 백필
-- ============================================================
-- PM 요청 — "협력사 관리에서 소재·공장정보·규제 다 들어와있어야". GlobalMining Corp·
-- Unverified Precursor Trading·신성배터리(주)·대성정밀(주) 4곳은 위반/Gray/온보딩초기/
-- HITL 시나리오상 의도적 결측이라 제외(그 외 전부 채움 — 한양셀 포함, 원래 있어야 했는데 누락돼 있었음).
INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
SELECT * FROM (VALUES
  -- 1차: 한양셀(누락분 재기입) · 동아셀(기존 의도적 갭 → PM 요청으로 채움)
  ('f1111111-0000-4000-8000-000000000001'::uuid, 2.3400::numeric, 'PEF', '2025-01-01'::date, '2025-01-01'::date, 'third_party_verified'),
  ('71444444-0000-4000-8000-000000000004'::uuid, 3.0500::numeric, 'PEF', '2024-03-01'::date, '2024-03-01'::date, 'supplier_declared'),
  -- 2차: CAM 제조사
  ('72333333-0000-4000-8000-000000000003'::uuid, 3.1500::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),  -- 신진CAM
  ('72666666-0000-4000-8000-000000000006'::uuid, 3.0800::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),  -- 청우CAM
  -- 3차: 전구체 제조사
  ('73111111-0000-4000-8000-000000000001'::uuid, 2.9200::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),  -- 동신전구체
  ('73222222-0000-4000-8000-000000000002'::uuid, 3.2200::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),  -- 대성전구체
  ('73333333-0000-4000-8000-000000000003'::uuid, 2.9800::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),  -- 한중정밀화학
  ('73444444-0000-4000-8000-000000000004'::uuid, 3.0500::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),  -- 세종프리커서
  ('73555555-0000-4000-8000-000000000005'::uuid, 3.1200::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),  -- 남해케미칼
  ('73666666-0000-4000-8000-000000000006'::uuid, 2.9500::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),  -- 은성정밀소재
  -- 4차: 제련소
  ('74111111-0000-4000-8000-000000000001'::uuid, 2.8000::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'third_party_verified'), -- 고려제련
  ('74222222-0000-4000-8000-000000000002'::uuid, 5.5000::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),    -- PT Indosel(고탄소·인니 화력)
  ('74333333-0000-4000-8000-000000000003'::uuid, 2.6000::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'third_party_verified'), -- AusRef
  ('74444444-0000-4000-8000-000000000004'::uuid, 4.8000::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),    -- Zambia Copper&Cobalt
  ('74555555-0000-4000-8000-000000000005'::uuid, 2.7500::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'third_party_verified'), -- Brazil Nickel Refining
  -- 5차: 광산(채굴 단계 배출량 — 정련소 대비 낮은 값)
  ('f9999999-0000-4000-8000-000000000009'::uuid, 0.4500::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),    -- 칠레리튬광업
  ('f3333333-0000-4000-8000-000000000003'::uuid, 0.4200::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'third_party_verified'), -- 호주리튬광업
  ('75111111-0000-4000-8000-000000000001'::uuid, 0.6800::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),    -- Sulawesi Nickel Mining
  ('75222222-0000-4000-8000-000000000002'::uuid, 0.7200::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),    -- Weda Bay Nickel Mine
  ('75333333-0000-4000-8000-000000000003'::uuid, 0.5000::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'third_party_verified'), -- Western Australia Nickel Mine
  ('75444444-0000-4000-8000-000000000004'::uuid, 0.8500::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'supplier_declared'),    -- Zambia Copperbelt Cobalt Mine
  ('75555555-0000-4000-8000-000000000005'::uuid, 0.5500::numeric, 'PEF', '2024-01-01'::date, '2024-01-01'::date, 'third_party_verified')  -- Brazil Nickel Laterite Mine
) AS v(factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
WHERE NOT EXISTS (SELECT 1 FROM factory_carbon_declarations WHERE factory_id = v.factory_id);


-- ============================================================
-- 24. 제조사 타입 "규제" 탭 표시 버그 수정 — supplier_manufacturer_details 백필
-- ============================================================
-- [원인] "규제" 탭(탄소집약도·에너지원)은 factory_carbon_declarations가 아니라
--   supplier_manufacturer_details 1건만 읽는다. tier2·tier3 신규 제조사 12곳에
--   이 테이블 행이 없어서 23번에서 채운 공장 탄소선언이 화면엔 안 보이던 것.
-- carbon_intensity는 23번에서 넣은 해당 공장 탄소선언 값과 맞춤.
INSERT INTO supplier_manufacturer_details (supplier_id, manufacturing_process, energy_source, capacity, carbon_intensity)
SELECT * FROM (VALUES
  ('62111111-0000-4000-8000-000000000001'::uuid, 'NCM Cathode Active Material Synthesis', 'mixed',     '6GWh/yr', 3.0500::numeric), -- 에코양극재
  ('62222222-0000-4000-8000-000000000002'::uuid, 'NCM Cathode Active Material Synthesis', 'mixed',     '5GWh/yr', 3.2100::numeric), -- 포스피케미칼
  ('62333333-0000-4000-8000-000000000003'::uuid, 'NCM Cathode Active Material Synthesis', 'mixed',     '4GWh/yr', 3.1500::numeric), -- 신진CAM
  ('62444444-0000-4000-8000-000000000004'::uuid, 'NCM Cathode Active Material Synthesis', 'renewable', '5GWh/yr', 3.1200::numeric), -- 한라소재
  ('62555555-0000-4000-8000-000000000005'::uuid, 'NCM Cathode Active Material Synthesis', 'mixed',     '6GWh/yr', 2.9500::numeric), -- 대한CAM
  ('62666666-0000-4000-8000-000000000006'::uuid, 'NCM Cathode Active Material Synthesis', 'mixed',     '4GWh/yr', 3.0800::numeric), -- 청우CAM
  ('63111111-0000-4000-8000-000000000001'::uuid, 'NCM Precursor Co-precipitation',        'mixed',     '10kt/yr', 2.9200::numeric), -- 동신전구체
  ('63222222-0000-4000-8000-000000000002'::uuid, 'NCM Precursor Co-precipitation',        'mixed',     '8kt/yr',  3.2200::numeric), -- 대성전구체
  ('63333333-0000-4000-8000-000000000003'::uuid, 'NCM Precursor Co-precipitation',        'mixed',     '9kt/yr',  2.9800::numeric), -- 한중정밀화학
  ('63444444-0000-4000-8000-000000000004'::uuid, 'NCM Precursor Co-precipitation',        'renewable', '7kt/yr',  3.0500::numeric), -- 세종프리커서
  ('63555555-0000-4000-8000-000000000005'::uuid, 'NCM Precursor Co-precipitation',        'mixed',     '8kt/yr',  3.1200::numeric), -- 남해케미칼
  ('63666666-0000-4000-8000-000000000006'::uuid, 'NCM Precursor Co-precipitation',        'mixed',     '9kt/yr',  2.9500::numeric)  -- 은성정밀소재
) AS v(supplier_id, manufacturing_process, energy_source, capacity, carbon_intensity)
WHERE NOT EXISTS (SELECT 1 FROM supplier_manufacturer_details WHERE supplier_id = v.supplier_id);


-- ============================================================
-- 25. CAM/전구체 제조사 14곳 + 제련소 7곳 다중공장 확장 (PM 요청)
-- ============================================================
-- 기존 하나에너지셀/한독배터리/성진셀 3곳에만 있던 다중공장을 21곳 더 확대.
-- 기존 공장(100%)을 60/40으로 분할하고 2번째 공장을 신규 추가(uuid_generate_v4 자동생성),
-- 엣지(edge_id)별로 공급비율/물량을 같은 비율로 재분배, 신규 공장 탄소선언도 함께 삽입.

-- 동성머티리얼(주) (천안 양극재공장 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('a2222222-2222-4000-8000-000000000002', '천안 제2공장', 'Cheonan CAM Plant 2', 'KR', 'Cheonan', ST_SetSRID(ST_MakePoint(127.364, 37.065), 4326), 'production', 'BOTH', '["EU_BATTERY", "CRMA", "CONFLICT_MINERALS"]'::jsonb, 40.00, '이도현', 'Plant Manager', '+82-41-000-0032', 'plant2.dy.choi@dongsungmat.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = 'f2222222-0000-4000-8000-000000000002' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.883::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '51111111-0000-4000-8000-000000000004'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 16000.0::numeric AS volume, 'kg' AS unit FROM new_factory
UNION ALL
SELECT '52222222-0000-4000-8000-000000000004'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 15200.0::numeric AS volume, 'kg' AS unit FROM new_factory
UNION ALL
SELECT '54444444-0000-4000-8000-000000000003'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 18000.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 24000.0 WHERE edge_id = '51111111-0000-4000-8000-000000000004' AND factory_id = 'f2222222-0000-4000-8000-000000000002';
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 22800.0 WHERE edge_id = '52222222-0000-4000-8000-000000000004' AND factory_id = 'f2222222-0000-4000-8000-000000000002';
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 27000.0 WHERE edge_id = '54444444-0000-4000-8000-000000000003' AND factory_id = 'f2222222-0000-4000-8000-000000000002';

-- 세종프리커서(주) (세종 전구체공장 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('63444444-0000-4000-8000-000000000004', '세종 제2공장', 'Sejong Precursor Plant 2', 'KR', 'Sejong', ST_SetSRID(ST_MakePoint(127.54, 36.73), 4326), 'production', 'EU', '["EU_BATTERY"]'::jsonb, 40.00, '박서연', 'Production Manager', '+82-44-444-3005', 'plant2.hy.cho@sejongpre.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '73444444-0000-4000-8000-000000000004' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.8365::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '88888888-0000-4000-8000-000000000004'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 8400.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 12600.0 WHERE edge_id = '88888888-0000-4000-8000-000000000004' AND factory_id = '73444444-0000-4000-8000-000000000004';

-- 은성정밀소재(주) (아산 정밀소재공장 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('63666666-0000-4000-8000-000000000006', '아산 제2공장', 'Asan Precision Materials Plant 2', 'KR', 'Asan', ST_SetSRID(ST_MakePoint(127.21, 37.03), 4326), 'production', 'BOTH', '["EU_BATTERY", "CRMA"]'::jsonb, 40.00, '김하늘', 'QA Manager', '+82-41-666-3007', 'plant2.dw.ko@eunsungmat.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '73666666-0000-4000-8000-000000000006' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.7435::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '8aaaaaaa-0000-4000-8000-000000000004'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 10000.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 15000.0 WHERE edge_id = '8aaaaaaa-0000-4000-8000-000000000004' AND factory_id = '73666666-0000-4000-8000-000000000006';

-- 포스피케미칼(주) (포항 CAM공장 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('62222222-0000-4000-8000-000000000002', '포항 제2공장', 'Pohang CAM Plant 2', 'KR', 'Pohang', ST_SetSRID(ST_MakePoint(129.63, 36.26), 4326), 'production', 'BOTH', '["EU_BATTERY", "CRMA"]'::jsonb, 40.00, '최윤서', 'Plant Manager', '+82-54-222-2003', 'plant2.th.shin@pospichem.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '72222222-0000-4000-8000-000000000002' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.9853::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '86666666-0000-4000-8000-000000000003'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 15200.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 22800.0 WHERE edge_id = '86666666-0000-4000-8000-000000000003' AND factory_id = '72222222-0000-4000-8000-000000000002';

-- 한중정밀화학(주) (포항 정밀화학공장 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('63333333-0000-4000-8000-000000000003', '포항 제2공장', 'Pohang Precision Chem Plant 2', 'KR', 'Pohang', ST_SetSRID(ST_MakePoint(129.625, 36.255), 4326), 'production', 'BOTH', '["EU_BATTERY", "CRMA"]'::jsonb, 40.00, '정재훈', 'Production Manager', '+82-54-333-3004', 'plant2.yl.ma@hanjungchem.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '73333333-0000-4000-8000-000000000003' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.7714::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '87777777-0000-4000-8000-000000000004'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 9600.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 14400.0 WHERE edge_id = '87777777-0000-4000-8000-000000000004' AND factory_id = '73333333-0000-4000-8000-000000000003';

-- 남해케미칼(주) (남해 케미칼공장 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('63555555-0000-4000-8000-000000000005', '남해 제2공장', 'Namhae Chemical Plant 2', 'KR', 'Namhae', ST_SetSRID(ST_MakePoint(128.115, 35.12), 4326), 'production', 'EU', '["EU_BATTERY"]'::jsonb, 40.00, '한소율', 'ESG Manager', '+82-55-555-3006', 'plant2.js.yang@namhaechem.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '73555555-0000-4000-8000-000000000005' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.9016::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '89999999-0000-4000-8000-000000000004'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 8800.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 13200.0 WHERE edge_id = '89999999-0000-4000-8000-000000000004' AND factory_id = '73555555-0000-4000-8000-000000000005';

-- 대성전구체(주) (화성 전구체공장 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('63222222-0000-4000-8000-000000000002', '화성 제2공장', 'Hwaseong Precursor Plant 2', 'KR', 'Hwaseong', ST_SetSRID(ST_MakePoint(127.1, 37.42), 4326), 'production', 'EU', '["EU_BATTERY"]'::jsonb, 40.00, '오지안', 'Plant Manager', '+82-31-222-3003', 'plant2.sk.han@daesungpre.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '73222222-0000-4000-8000-000000000002' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.9946::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '86666666-0000-4000-8000-000000000004'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 9200.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 13800.0 WHERE edge_id = '86666666-0000-4000-8000-000000000004' AND factory_id = '73222222-0000-4000-8000-000000000002';

-- 동신전구체(주) (군산 전구체공장 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('63111111-0000-4000-8000-000000000001', '군산 제2공장', 'Gunsan Precursor Plant 2', 'KR', 'Gunsan', ST_SetSRID(ST_MakePoint(126.965, 36.215), 4326), 'production', 'EU', '["EU_BATTERY", "CRMA"]'::jsonb, 40.00, '배수민', 'Production Manager', '+82-63-111-3002', 'plant2.cw.bae@dongsinpre.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '73111111-0000-4000-8000-000000000001' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.7156::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '85555555-0000-4000-8000-000000000005'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 10000.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 15000.0 WHERE edge_id = '85555555-0000-4000-8000-000000000005' AND factory_id = '73111111-0000-4000-8000-000000000001';

-- 에코양극재(주) (천안 양극재공장 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('62111111-0000-4000-8000-000000000001', '천안 제2공장', 'Cheonan CAM Plant 2', 'KR', 'Cheonan', ST_SetSRID(ST_MakePoint(127.35, 37.06), 4326), 'production', 'BOTH', '["EU_BATTERY", "CRMA", "EU_BATTERY_ART7"]'::jsonb, 40.00, '장서준', 'Plant Manager', '+82-41-111-2002', 'plant2.bk.yoon@ecocathode.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '72111111-0000-4000-8000-000000000001' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.8365::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '85555555-0000-4000-8000-000000000004'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 16800.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 25200.0 WHERE edge_id = '85555555-0000-4000-8000-000000000004' AND factory_id = '72111111-0000-4000-8000-000000000001';

-- 청정전구체(주) (광양 전구체공장 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('a6666666-6666-4000-8000-000000000006', '광양 제2공장', 'Gwangyang Precursor 2', 'KR', 'Gwangyang', ST_SetSRID(ST_MakePoint(127.95, 35.19), 4326), 'production', 'BOTH', '["EU_BATTERY", "CRMA"]'::jsonb, 40.00, '임채원', 'Production Manager', '+82-61-000-0042', 'plant2.hy.jung@cheongjeongpre.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = 'f6666666-0000-4000-8000-000000000006' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 3.2085::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '53111111-0000-4000-8000-000000000003'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 8800.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 13200.0 WHERE edge_id = '53111111-0000-4000-8000-000000000003' AND factory_id = 'f6666666-0000-4000-8000-000000000006';

-- 한라소재(주) (거제 소재공장 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('62444444-0000-4000-8000-000000000004', '거제 제2공장', 'Geoje Materials Plant 2', 'KR', 'Geoje', ST_SetSRID(ST_MakePoint(128.871, 35.129), 4326), 'production', 'EU', '["EU_BATTERY", "CRMA"]'::jsonb, 40.00, '황도윤', 'QA Manager', '+82-55-444-2005', 'plant2.ys.kwon@hallamat.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '72444444-0000-4000-8000-000000000004' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.9016::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '88888888-0000-4000-8000-000000000003'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 14400.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 21600.0 WHERE edge_id = '88888888-0000-4000-8000-000000000003' AND factory_id = '72444444-0000-4000-8000-000000000004';

-- 대한CAM(주) (울산 CAM공장 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('62555555-0000-4000-8000-000000000005', '울산 제2공장', 'Ulsan CAM Plant 2', 'KR', 'Ulsan', ST_SetSRID(ST_MakePoint(129.615, 35.77), 4326), 'production', 'BOTH', '["EU_BATTERY", "CRMA", "EU_BATTERY_ART7"]'::jsonb, 40.00, '송하린', 'Plant Manager', '+82-52-555-2006', 'plant2.jw.baek@daehancam.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '72555555-0000-4000-8000-000000000005' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.7435::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '89999999-0000-4000-8000-000000000003'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 14800.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 22200.0 WHERE edge_id = '89999999-0000-4000-8000-000000000003' AND factory_id = '72555555-0000-4000-8000-000000000005';

-- 신진CAM(주) (군산 CAM공장 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('62333333-0000-4000-8000-000000000003', '군산 제2공장', 'Gunsan CAM Plant 2', 'KR', 'Gunsan', ST_SetSRID(ST_MakePoint(126.961, 36.217), 4326), 'production', 'EU', '["EU_BATTERY"]'::jsonb, 40.00, '문지호', 'Production Manager', '+82-63-333-2004', 'plant2.ms.kwak@sinjincam.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '72333333-0000-4000-8000-000000000003' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.9295::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '87777777-0000-4000-8000-000000000003'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 16000.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 24000.0 WHERE edge_id = '87777777-0000-4000-8000-000000000003' AND factory_id = '72333333-0000-4000-8000-000000000003';

-- 청우CAM(주) (이천 CAM공장 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('62666666-0000-4000-8000-000000000006', '이천 제2공장', 'Icheon CAM Plant 2', 'KR', 'Icheon', ST_SetSRID(ST_MakePoint(127.755, 37.496), 4326), 'production', 'EU', '["EU_BATTERY"]'::jsonb, 40.00, '신유나', 'Plant Manager', '+82-31-666-2007', 'plant2.hj.nam@cheongwoocam.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '72666666-0000-4000-8000-000000000006' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.8644::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '8aaaaaaa-0000-4000-8000-000000000003'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 16800.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 25200.0 WHERE edge_id = '8aaaaaaa-0000-4000-8000-000000000003' AND factory_id = '72666666-0000-4000-8000-000000000006';

-- 고려제련(주) (온산 제련소 2호 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('64111111-0000-4000-8000-000000000001', '온산 제2제련소', 'Onsan Smelter No.3', 'KR', 'Onsan', ST_SetSRID(ST_MakePoint(129.6, 35.68), 4326), 'processing', 'BOTH', '["CRMA", "EU_BATTERY"]'::jsonb, 40.00, '이도현', 'Plant Manager', '+82-52-111-4002', 'plant2.jang@koryosmelt.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '74111111-0000-4000-8000-000000000001' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.604::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '85555555-0000-4000-8000-000000000006'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 8000.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 12000.0 WHERE edge_id = '85555555-0000-4000-8000-000000000006' AND factory_id = '74111111-0000-4000-8000-000000000001';

-- 한중제련(주) (온산 제련소 -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('aaaaaaaa-aaaa-4000-8000-00000000000a', '온산 제2제련소', 'Onsan Refinery 2', 'KR', 'Onsan', ST_SetSRID(ST_MakePoint(129.597, 35.678), 4326), 'processing', 'BOTH', '["IRA", "CRMA"]'::jsonb, 40.00, '박서연', 'Production Manager', '+82-52-000-0062', 'plant2.sm.yoon@hanjungref.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = 'faaaaaaa-0000-4000-8000-00000000000a' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.697::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '51111111-0000-4000-8000-000000000005'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 9600.0::numeric AS volume, 'kg' AS unit FROM new_factory
UNION ALL
SELECT '54444444-0000-4000-8000-000000000004'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 10000.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 14400.0 WHERE edge_id = '51111111-0000-4000-8000-000000000005' AND factory_id = 'faaaaaaa-0000-4000-8000-00000000000a';
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 15000.0 WHERE edge_id = '54444444-0000-4000-8000-000000000004' AND factory_id = 'faaaaaaa-0000-4000-8000-00000000000a';

-- AusRef Processing Pty Ltd (Kwinana Ni Refinery -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('64333333-0000-4000-8000-000000000003', 'Kwinana Ni Refinery 2', 'Kwinana Ni Refinery 2', 'AU', 'Western Australia', ST_SetSRID(ST_MakePoint(116.02, -31.98), 4326), 'processing', 'BOTH', '["CRMA"]'::jsonb, 40.00, 'David Chen', 'Plant Manager', '+61-8-333-4004', 'plant2.j.wilson@ausref.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '74333333-0000-4000-8000-000000000003' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.418::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '87777777-0000-4000-8000-000000000005'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 7600.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 11400.0 WHERE edge_id = '87777777-0000-4000-8000-000000000005' AND factory_id = '74333333-0000-4000-8000-000000000003';

-- Brazil Nickel Refining SA (Niquelândia Refinery -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('64555555-0000-4000-8000-000000000005', 'Niquelândia Refinery 2', 'Niquelandia Refinery 2', 'BR', 'Goias', ST_SetSRID(ST_MakePoint(-48.21, -14.22), 4326), 'processing', 'BOTH', '["CRMA"]'::jsonb, 40.00, 'Maria Santos', 'Production Manager', '+55-62-555-4006', 'plant2.c.silva@brnickel.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '74555555-0000-4000-8000-000000000005' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.5575::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '89999999-0000-4000-8000-000000000005'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 7000.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 10500.0 WHERE edge_id = '89999999-0000-4000-8000-000000000005' AND factory_id = '74555555-0000-4000-8000-000000000005';

-- PT Indosel Nickel Refinery (Morowali Refinery -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('64222222-0000-4000-8000-000000000002', 'Morowali Refinery 2', 'Morowali Refinery 2', 'ID', 'Sulawesi', ST_SetSRID(ST_MakePoint(121.89, -1.76), 4326), 'processing', 'BOTH', '["CRMA", "CONFLICT_MINERALS", "EUDR"]'::jsonb, 40.00, 'Ahmad Rahman', 'Plant Manager', '+62-21-222-4003', 'plant2.budi@indosel.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '74222222-0000-4000-8000-000000000002' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 5.115::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '86666666-0000-4000-8000-000000000005'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 7400.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 11100.0 WHERE edge_id = '86666666-0000-4000-8000-000000000005' AND factory_id = '74222222-0000-4000-8000-000000000002';

-- Xinjiang Nickel Refinery (Xinjiang Refinery -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('acacacac-acac-4000-8000-0000000000ac', 'Xinjiang Refinery 2', 'Xinjiang Refinery 2', 'CN', 'Xinjiang', ST_SetSRID(ST_MakePoint(86.4, 41.37), 4326), 'processing', 'US', '["UFLPA", "IRA"]'::jsonb, 40.00, 'Li Ming', 'Production Manager', '+86-991-000-0052', 'plant2.w.chen@xjrefinery.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = 'facacaca-0000-4000-8000-0000000000ac' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 4.836::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '53222222-0000-4000-8000-000000000003'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 8800.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 13200.0 WHERE edge_id = '53222222-0000-4000-8000-000000000003' AND factory_id = 'facacaca-0000-4000-8000-0000000000ac';

-- Zambia Copper & Cobalt Refinery (Kitwe Refinery -> +2번째 공장)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('64444444-0000-4000-8000-000000000004', 'Kitwe Refinery 2', 'Kitwe Refinery 2', 'ZM', 'Copperbelt', ST_SetSRID(ST_MakePoint(28.463, -12.568), 4326), 'processing', 'BOTH', '["CONFLICT_MINERALS", "CRMA"]'::jsonb, 40.00, 'Grace Mwansa', 'Compliance Manager', '+260-212-444-4005', 'plant2.e.banda@zamcopper.demo')
  RETURNING factory_id
),
upd_old_factory AS (
  UPDATE supplier_factories SET supply_ratio_percent = 60.00 WHERE factory_id = '74444444-0000-4000-8000-000000000004' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 4.464::numeric, 'PEF', '2024-06-01'::date, '2024-06-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '88888888-0000-4000-8000-000000000005'::uuid AS edge_id, factory_id, 40.00::numeric AS ratio_percentage, 6800.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 60.00, volume = 10200.0 WHERE edge_id = '88888888-0000-4000-8000-000000000005' AND factory_id = '74444444-0000-4000-8000-000000000004';


-- ============================================================
-- 26. 다중공장 12곳 2->3개 확장 (PM 요청: 2~3개 다양화)
-- ============================================================
-- 기존 2공장(60/40 또는 70/30) 체제였던 12곳을 3공장(50/30/20)으로 재분배.
-- 기존 두 공장의 supply_ratio_percent/supply_ratio(엣지별 volume)를 50/30으로 낮추고,
-- 3번째 공장을 신규 추가(20%), 탄소선언도 함께 삽입.

-- 세종프리커서(주) (3번째 공장 추가, 50/30/20 재분배)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('63444444-0000-4000-8000-000000000004', '세종 제3공장', 'Sejong Precursor Plant 3', 'KR', 'Sejong', ST_SetSRID(ST_MakePoint(127.74, 36.13), 4326), 'production', 'EU', '["EU_BATTERY"]'::jsonb, 20.00, '서지우', 'Plant Manager', '+82-44-444-3006', 'plant3.hy.cho@sejongpre.demo')
  RETURNING factory_id
),
upd_primary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 50.00 WHERE factory_id = '73444444-0000-4000-8000-000000000004' RETURNING factory_id
),
upd_secondary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 30.00 WHERE factory_id = 'ed48f9c1-8cac-4634-b0a3-35509aac9fd3' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.745::numeric, 'PEF', '2024-09-01'::date, '2024-09-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '88888888-0000-4000-8000-000000000004'::uuid AS edge_id, factory_id, 20.00::numeric AS ratio_percentage, 4200.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 50.00, volume = 10500.0 WHERE edge_id = '88888888-0000-4000-8000-000000000004' AND factory_id = '73444444-0000-4000-8000-000000000004';
UPDATE supply_ratio SET ratio_percentage = 30.00, volume = 6300.0 WHERE edge_id = '88888888-0000-4000-8000-000000000004' AND factory_id = 'ed48f9c1-8cac-4634-b0a3-35509aac9fd3';

-- 포스피케미칼(주) (3번째 공장 추가, 50/30/20 재분배)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('62222222-0000-4000-8000-000000000002', '포항 제3공장', 'Pohang CAM Plant 3', 'KR', 'Pohang', ST_SetSRID(ST_MakePoint(129.83, 35.66), 4326), 'production', 'BOTH', '["EU_BATTERY", "CRMA"]'::jsonb, 20.00, '강태민', 'Production Manager', '+82-54-222-2004', 'plant3.th.shin@pospichem.demo')
  RETURNING factory_id
),
upd_primary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 50.00 WHERE factory_id = '72222222-0000-4000-8000-000000000002' RETURNING factory_id
),
upd_secondary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 30.00 WHERE factory_id = 'db0de79f-e282-4b25-8a22-4d009e1fa746' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.889::numeric, 'PEF', '2024-09-01'::date, '2024-09-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '86666666-0000-4000-8000-000000000003'::uuid AS edge_id, factory_id, 20.00::numeric AS ratio_percentage, 7600.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 50.00, volume = 19000.0 WHERE edge_id = '86666666-0000-4000-8000-000000000003' AND factory_id = '72222222-0000-4000-8000-000000000002';
UPDATE supply_ratio SET ratio_percentage = 30.00, volume = 11400.0 WHERE edge_id = '86666666-0000-4000-8000-000000000003' AND factory_id = 'db0de79f-e282-4b25-8a22-4d009e1fa746';

-- 하나에너지셀(주) (3번째 공장 추가, 50/30/20 재분배)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('61222222-0000-4000-8000-000000000002', '오송 제3공장', 'Osong Cell Plant 3', 'KR', 'Cheongju', ST_SetSRID(ST_MakePoint(127.794, 36.284), 4326), 'production', 'EU', '["EU_BATTERY", "EU_BATTERY_ART7", "CSDDD"]'::jsonb, 20.00, '윤아린', 'QA Manager', '+82-43-222-0003', 'plant3.sy.choi@hanaenergy.demo')
  RETURNING factory_id
),
upd_primary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 50.00 WHERE factory_id = '71222222-0000-4000-8000-000000000002' RETURNING factory_id
),
upd_secondary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 30.00 WHERE factory_id = '71222223-0000-4000-8000-000000000002' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.079::numeric, 'PEF', '2024-09-01'::date, '2024-09-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '86666666-0000-4000-8000-000000000002'::uuid AS edge_id, factory_id, 20.00::numeric AS ratio_percentage, 1840.0::numeric AS volume, 'ea' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 50.00, volume = 4600.0 WHERE edge_id = '86666666-0000-4000-8000-000000000002' AND factory_id = '71222222-0000-4000-8000-000000000002';
UPDATE supply_ratio SET ratio_percentage = 30.00, volume = 2760.0 WHERE edge_id = '86666666-0000-4000-8000-000000000002' AND factory_id = '71222223-0000-4000-8000-000000000002';

-- 남해케미칼(주) (3번째 공장 추가, 50/30/20 재분배)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('63555555-0000-4000-8000-000000000005', '남해 제3공장', 'Namhae Chemical Plant 3', 'KR', 'Namhae', ST_SetSRID(ST_MakePoint(128.315, 34.52), 4326), 'production', 'EU', '["EU_BATTERY"]'::jsonb, 20.00, '조은채', 'Plant Manager', '+82-55-555-3007', 'plant3.js.yang@namhaechem.demo')
  RETURNING factory_id
),
upd_primary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 50.00 WHERE factory_id = '73555555-0000-4000-8000-000000000005' RETURNING factory_id
),
upd_secondary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 30.00 WHERE factory_id = 'c292f097-bf0c-4212-9942-e5ffbbbb43ca' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.808::numeric, 'PEF', '2024-09-01'::date, '2024-09-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '89999999-0000-4000-8000-000000000004'::uuid AS edge_id, factory_id, 20.00::numeric AS ratio_percentage, 4400.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 50.00, volume = 11000.0 WHERE edge_id = '89999999-0000-4000-8000-000000000004' AND factory_id = '73555555-0000-4000-8000-000000000005';
UPDATE supply_ratio SET ratio_percentage = 30.00, volume = 6600.0 WHERE edge_id = '89999999-0000-4000-8000-000000000004' AND factory_id = 'c292f097-bf0c-4212-9942-e5ffbbbb43ca';

-- 동신전구체(주) (3번째 공장 추가, 50/30/20 재분배)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('63111111-0000-4000-8000-000000000001', '군산 제3공장', 'Gunsan Precursor Plant 3', 'KR', 'Gunsan', ST_SetSRID(ST_MakePoint(127.165, 35.615), 4326), 'production', 'EU', '["EU_BATTERY", "CRMA"]'::jsonb, 20.00, '남궁윤', 'Production Manager', '+82-63-111-3003', 'plant3.cw.bae@dongsinpre.demo')
  RETURNING factory_id
),
upd_primary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 50.00 WHERE factory_id = '73111111-0000-4000-8000-000000000001' RETURNING factory_id
),
upd_secondary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 30.00 WHERE factory_id = '686c97e5-7c44-42a2-8a7c-2c932f24d182' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.628::numeric, 'PEF', '2024-09-01'::date, '2024-09-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '85555555-0000-4000-8000-000000000005'::uuid AS edge_id, factory_id, 20.00::numeric AS ratio_percentage, 5000.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 50.00, volume = 12500.0 WHERE edge_id = '85555555-0000-4000-8000-000000000005' AND factory_id = '73111111-0000-4000-8000-000000000001';
UPDATE supply_ratio SET ratio_percentage = 30.00, volume = 7500.0 WHERE edge_id = '85555555-0000-4000-8000-000000000005' AND factory_id = '686c97e5-7c44-42a2-8a7c-2c932f24d182';

-- 청정전구체(주) (3번째 공장 추가, 50/30/20 재분배)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('a6666666-6666-4000-8000-000000000006', '광양 제3공장', 'Gwangyang Precursor 3', 'KR', 'Gwangyang', ST_SetSRID(ST_MakePoint(128.15, 34.59), 4326), 'production', 'BOTH', '["EU_BATTERY", "CRMA"]'::jsonb, 20.00, '전민재', 'ESG Manager', '+82-61-000-0043', 'plant3.hy.jung@cheongjeongpre.demo')
  RETURNING factory_id
),
upd_primary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 50.00 WHERE factory_id = 'f6666666-0000-4000-8000-000000000006' RETURNING factory_id
),
upd_secondary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 30.00 WHERE factory_id = 'a71be771-2add-42bd-9a8e-b610c653e927' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 3.105::numeric, 'PEF', '2024-09-01'::date, '2024-09-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '53111111-0000-4000-8000-000000000003'::uuid AS edge_id, factory_id, 20.00::numeric AS ratio_percentage, 4400.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 50.00, volume = 11000.0 WHERE edge_id = '53111111-0000-4000-8000-000000000003' AND factory_id = 'f6666666-0000-4000-8000-000000000006';
UPDATE supply_ratio SET ratio_percentage = 30.00, volume = 6600.0 WHERE edge_id = '53111111-0000-4000-8000-000000000003' AND factory_id = 'a71be771-2add-42bd-9a8e-b610c653e927';

-- 한독배터리(주) (3번째 공장 추가, 50/30/20 재분배)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('61555555-0000-4000-8000-000000000005', '구미 제3공장', 'Gumi Battery Plant 3', 'KR', 'Gumi', ST_SetSRID(ST_MakePoint(128.769, 35.769), 4326), 'production', 'BOTH', '["EU_BATTERY", "EU_BATTERY_ART7", "EU_BATTERY_ART47", "CSDDD"]'::jsonb, 20.00, '구해나', 'Plant Manager', '+82-54-555-0003', 'plant3.kw.jung@handokbattery.demo')
  RETURNING factory_id
),
upd_primary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 50.00 WHERE factory_id = '71555555-0000-4000-8000-000000000005' RETURNING factory_id
),
upd_secondary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 30.00 WHERE factory_id = '71555556-0000-4000-8000-000000000005' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 1.998::numeric, 'PEF', '2024-09-01'::date, '2024-09-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '89999999-0000-4000-8000-000000000002'::uuid AS edge_id, factory_id, 20.00::numeric AS ratio_percentage, 1760.0::numeric AS volume, 'ea' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 50.00, volume = 4400.0 WHERE edge_id = '89999999-0000-4000-8000-000000000002' AND factory_id = '71555555-0000-4000-8000-000000000005';
UPDATE supply_ratio SET ratio_percentage = 30.00, volume = 2640.0 WHERE edge_id = '89999999-0000-4000-8000-000000000002' AND factory_id = '71555556-0000-4000-8000-000000000005';

-- 고려제련(주) (3번째 공장 추가, 50/30/20 재분배)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('64111111-0000-4000-8000-000000000001', '온산 제3제련소', 'Onsan Smelter No.2 3', 'KR', 'Onsan', ST_SetSRID(ST_MakePoint(129.8, 35.08), 4326), 'processing', 'BOTH', '["CRMA", "EU_BATTERY"]'::jsonb, 20.00, '표승주', 'Production Manager', '+82-52-111-4003', 'plant3.jang@koryosmelt.demo')
  RETURNING factory_id
),
upd_primary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 50.00 WHERE factory_id = '74111111-0000-4000-8000-000000000001' RETURNING factory_id
),
upd_secondary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 30.00 WHERE factory_id = '47213770-8ea8-4dbd-9af8-749402efa9a3' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.52::numeric, 'PEF', '2024-09-01'::date, '2024-09-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '85555555-0000-4000-8000-000000000006'::uuid AS edge_id, factory_id, 20.00::numeric AS ratio_percentage, 4000.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 50.00, volume = 10000.0 WHERE edge_id = '85555555-0000-4000-8000-000000000006' AND factory_id = '74111111-0000-4000-8000-000000000001';
UPDATE supply_ratio SET ratio_percentage = 30.00, volume = 6000.0 WHERE edge_id = '85555555-0000-4000-8000-000000000006' AND factory_id = '47213770-8ea8-4dbd-9af8-749402efa9a3';

-- 한중제련(주) (3번째 공장 추가, 50/30/20 재분배)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('aaaaaaaa-aaaa-4000-8000-00000000000a', '온산 제3제련소', 'Onsan Refinery 3', 'KR', 'Onsan', ST_SetSRID(ST_MakePoint(129.797, 35.078), 4326), 'processing', 'BOTH', '["IRA", "CRMA"]'::jsonb, 20.00, '주다인', 'Plant Manager', '+82-52-000-0063', 'plant3.sm.yoon@hanjungref.demo')
  RETURNING factory_id
),
upd_primary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 50.00 WHERE factory_id = 'faaaaaaa-0000-4000-8000-00000000000a' RETURNING factory_id
),
upd_secondary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 30.00 WHERE factory_id = 'e3ae46e6-975d-43c2-8ab1-0ee8ec90bf13' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.61::numeric, 'PEF', '2024-09-01'::date, '2024-09-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '51111111-0000-4000-8000-000000000005'::uuid AS edge_id, factory_id, 20.00::numeric AS ratio_percentage, 4800.0::numeric AS volume, 'kg' AS unit FROM new_factory
UNION ALL
SELECT '54444444-0000-4000-8000-000000000004'::uuid AS edge_id, factory_id, 20.00::numeric AS ratio_percentage, 5000.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 50.00, volume = 12000.0 WHERE edge_id = '51111111-0000-4000-8000-000000000005' AND factory_id = 'faaaaaaa-0000-4000-8000-00000000000a';
UPDATE supply_ratio SET ratio_percentage = 50.00, volume = 12500.0 WHERE edge_id = '54444444-0000-4000-8000-000000000004' AND factory_id = 'faaaaaaa-0000-4000-8000-00000000000a';
UPDATE supply_ratio SET ratio_percentage = 30.00, volume = 7200.0 WHERE edge_id = '51111111-0000-4000-8000-000000000005' AND factory_id = 'e3ae46e6-975d-43c2-8ab1-0ee8ec90bf13';
UPDATE supply_ratio SET ratio_percentage = 30.00, volume = 7500.0 WHERE edge_id = '54444444-0000-4000-8000-000000000004' AND factory_id = 'e3ae46e6-975d-43c2-8ab1-0ee8ec90bf13';

-- Brazil Nickel Refining SA (3번째 공장 추가, 50/30/20 재분배)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('64555555-0000-4000-8000-000000000005', 'Niquelândia Refinery 3', 'Niquelandia Refinery 3', 'BR', 'Goias', ST_SetSRID(ST_MakePoint(-48.01, -14.82), 4326), 'processing', 'BOTH', '["CRMA"]'::jsonb, 20.00, 'Fernando Reyes', 'Plant Manager', '+55-62-555-4007', 'plant3.c.silva@brnickel.demo')
  RETURNING factory_id
),
upd_primary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 50.00 WHERE factory_id = '74555555-0000-4000-8000-000000000005' RETURNING factory_id
),
upd_secondary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 30.00 WHERE factory_id = 'c0a6e2cd-4181-4a30-8716-363cad1401a1' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.475::numeric, 'PEF', '2024-09-01'::date, '2024-09-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '89999999-0000-4000-8000-000000000005'::uuid AS edge_id, factory_id, 20.00::numeric AS ratio_percentage, 3500.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 50.00, volume = 8750.0 WHERE edge_id = '89999999-0000-4000-8000-000000000005' AND factory_id = '74555555-0000-4000-8000-000000000005';
UPDATE supply_ratio SET ratio_percentage = 30.00, volume = 5250.0 WHERE edge_id = '89999999-0000-4000-8000-000000000005' AND factory_id = 'c0a6e2cd-4181-4a30-8716-363cad1401a1';

-- 신진CAM(주) (3번째 공장 추가, 50/30/20 재분배)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('62333333-0000-4000-8000-000000000003', '군산 제3공장', 'Gunsan CAM Plant 3', 'KR', 'Gunsan', ST_SetSRID(ST_MakePoint(127.161, 35.617), 4326), 'production', 'EU', '["EU_BATTERY"]'::jsonb, 20.00, '허지완', 'Production Manager', '+82-63-333-2005', 'plant3.ms.kwak@sinjincam.demo')
  RETURNING factory_id
),
upd_primary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 50.00 WHERE factory_id = '72333333-0000-4000-8000-000000000003' RETURNING factory_id
),
upd_secondary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 30.00 WHERE factory_id = '1303efc1-70d8-410a-a091-0c5341ad611e' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 2.835::numeric, 'PEF', '2024-09-01'::date, '2024-09-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '87777777-0000-4000-8000-000000000003'::uuid AS edge_id, factory_id, 20.00::numeric AS ratio_percentage, 8000.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 50.00, volume = 20000.0 WHERE edge_id = '87777777-0000-4000-8000-000000000003' AND factory_id = '72333333-0000-4000-8000-000000000003';
UPDATE supply_ratio SET ratio_percentage = 30.00, volume = 12000.0 WHERE edge_id = '87777777-0000-4000-8000-000000000003' AND factory_id = '1303efc1-70d8-410a-a091-0c5341ad611e';

-- Xinjiang Nickel Refinery (3번째 공장 추가, 50/30/20 재분배)
WITH new_factory AS (
  INSERT INTO supplier_factories (supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent, factory_manager_name, factory_manager_role, factory_manager_phone, factory_manager_email)
  VALUES ('acacacac-acac-4000-8000-0000000000ac', 'Xinjiang Refinery 3', 'Xinjiang Refinery 3', 'CN', 'Xinjiang', ST_SetSRID(ST_MakePoint(86.6, 40.77), 4326), 'processing', 'US', '["UFLPA", "IRA"]'::jsonb, 20.00, 'Wang Lei', 'Production Manager', '+86-991-000-0053', 'plant3.w.chen@xjrefinery.demo')
  RETURNING factory_id
),
upd_primary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 50.00 WHERE factory_id = 'facacaca-0000-4000-8000-0000000000ac' RETURNING factory_id
),
upd_secondary AS (
  UPDATE supplier_factories SET supply_ratio_percent = 30.00 WHERE factory_id = '8203ba63-ad8f-4b48-a278-064e91cfbf9e' RETURNING factory_id
),
new_carbon AS (
  INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source)
  SELECT factory_id, 4.68::numeric, 'PEF', '2024-09-01'::date, '2024-09-01'::date, 'supplier_declared' FROM new_factory
  RETURNING declaration_id
)
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit)
SELECT '53222222-0000-4000-8000-000000000003'::uuid AS edge_id, factory_id, 20.00::numeric AS ratio_percentage, 4400.0::numeric AS volume, 'kg' AS unit FROM new_factory;
UPDATE supply_ratio SET ratio_percentage = 50.00, volume = 11000.0 WHERE edge_id = '53222222-0000-4000-8000-000000000003' AND factory_id = 'facacaca-0000-4000-8000-0000000000ac';
UPDATE supply_ratio SET ratio_percentage = 30.00, volume = 6600.0 WHERE edge_id = '53222222-0000-4000-8000-000000000003' AND factory_id = '8203ba63-ad8f-4b48-a278-064e91cfbf9e';


-- ============================================================
-- 18-B. IONIQ 6 음극(흑연) 공급망 분기 — Annex X 실사 4종 완성
-- ============================================================
-- 배경: 기존 11개 체인이 전부 양극 라인이라 EU 배터리법 Annex X 실사 대상
--   4종(Co·Li·Ni·천연흑연) 중 천연흑연 데이터가 없었다. parts의 ANO-GRAPHITE
--   (b1111111-…007)는 정의만 있고 미배선 상태였음.
-- 구성: 완주 체인 IONIQ 6(e7777777)에 음극 분기 3개사 추가(전부 verified —
--   완주 상태 유지, 발송 이력은 아래 섹션 19가 자동 생성).
--   성진셀(1차) → 한빛음극재(hop2) → Qingdao 구형화 가공(hop3)
--   → Balama 천연흑연 광산(hop4, 모잠비크 카보델가도 — 분쟁 인접 지역 시나리오)
-- core_minerals: 천연/인조 흑연을 키로 구분(graphite_natural만 Annex X 실사 대상).

-- 신규 품목 2개 — ANO(활물질, tier3) 하위 가공·원광
INSERT INTO parts (part_id, part_code, part_name, tier_level, parent_part_id, hs_code, material_type, unit_price, source_system, external_id) VALUES
('b1111111-0000-4000-8000-000000000014', 'PROC-GRAPHITE', 'Spherical Graphite (Purified)', 5, 'b1111111-0000-4000-8000-000000000007', '250410', 'refined_metal', 14.0000, 'ERP_PLM', 'ERP-PART-PROCGR'),
('b1111111-0000-4000-8000-000000000015', 'MIN-GRAPHITE',  'Natural Graphite Ore (Flake)',  6, 'b1111111-0000-4000-8000-000000000014', '250410', 'mineral',        6.0000, 'ERP_PLM', 'ERP-PART-MINGR');

-- 협력사 3개사 (2차 음극재 제조 / 3차 구형화 가공 / 4차 천연흑연 광산)
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, ceo_name, business_reg_no, provider_type, core_minerals, country, address, business_reg_doc_url, environmental_report_url, completeness_score, status, risk_level) VALUES
('66111111-0000-4000-8000-000000000001', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '한빛음극재(주)', 'Hanbit Anode Materials', 'Seo YJ CEO', '661-86-30001', 'manufacturer', '{"graphite_natural":88.0,"graphite_synthetic":12.0}'::jsonb, 'KR', '경상북도 포항시 북구 흥해읍 영일만산단로 77', 's3://kira-docs/suppliers/66111111/biz_reg.pdf', 's3://kira-docs/suppliers/66111111/env_report.pdf', 84, 'supplier_verified', 'low'),
('66222222-0000-4000-8000-000000000002', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Qingdao Spherical Graphite Co.', 'Qingdao Spherical Graphite Co.', 'Chen CEO', NULL, 'smelter', '{"graphite_natural":95.0}'::jsonb, 'CN', 'Laixi Graphite Industrial Park, Qingdao, Shandong', 's3://kira-docs/suppliers/66222222/biz_reg.pdf', NULL, 71, 'supplier_verified', 'low'),
('66333333-0000-4000-8000-000000000003', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Balama Graphite Mining SA', 'Balama Graphite Mining SA', 'Machel CEO', NULL, 'miner', NULL, 'MZ', 'Balama District, Cabo Delgado Province', 's3://kira-docs/suppliers/66333333/biz_reg.pdf', NULL, 58, 'supplier_verified', 'medium');

INSERT INTO supplier_factories (factory_id, supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent) VALUES
('76111111-0000-4000-8000-000000000001', '66111111-0000-4000-8000-000000000001', '포항 음극재공장', 'Pohang Anode Plant', 'KR', 'Pohang', ST_SetSRID(ST_MakePoint(129.385, 36.077), 4326), 'production', 'BOTH', '["EU_BATTERY","EU_BATTERY_ART7","EU_BATTERY_ART47","CSDDD"]'::jsonb, 100.00),
('76222222-0000-4000-8000-000000000002', '66222222-0000-4000-8000-000000000002', 'Laixi Spheroidization Plant', 'Laixi Spheroidization Plant', 'CN', 'Qingdao', ST_SetSRID(ST_MakePoint(120.518, 36.889), 4326), 'processing', 'BOTH', '["EU_BATTERY_ART47","CSDDD","CBAM"]'::jsonb, 100.00),
('76333333-0000-4000-8000-000000000003', '66333333-0000-4000-8000-000000000003', 'Balama Graphite Mine', 'Balama Graphite Mine', 'MZ', 'Cabo Delgado', ST_SetSRID(ST_MakePoint(38.575, -13.348), 4326), 'mining', 'BOTH', '["EU_BATTERY_ART47","CRMA","EUDR"]'::jsonb, 100.00);

INSERT INTO supplier_contacts (supplier_id, factory_id, name, name_en, role, department, email, phone, is_primary, language) VALUES
('66111111-0000-4000-8000-000000000001', '76111111-0000-4000-8000-000000000001', '서유진', 'Seo YJ', 'ESG Manager', 'ESG팀', 'yj.seo@hanbitanode.demo', '+82-54-661-0001', TRUE, 'ko'),
('66111111-0000-4000-8000-000000000001', '76111111-0000-4000-8000-000000000001', '문태호', 'Moon TH', 'Quality Manager', '품질팀', 'th.moon@hanbitanode.demo', '+82-54-661-0002', FALSE, 'ko'),
('66222222-0000-4000-8000-000000000002', '76222222-0000-4000-8000-000000000002', 'Chen Xiaolin', 'Chen Xiaolin', 'Compliance Manager', 'Compliance', 'xl.chen@qdgraphite.demo', '+86-532-662-0001', TRUE, 'en'),
('66333333-0000-4000-8000-000000000003', '76333333-0000-4000-8000-000000000003', 'Amina Machel', 'Amina Machel', 'Mine Manager', 'Operations', 'a.machel@balamagraphite.demo', '+258-27-663-0001', TRUE, 'en');

INSERT INTO supplier_manufacturer_details (supplier_id, manufacturing_process, energy_source, capacity, carbon_intensity) VALUES
('66111111-0000-4000-8000-000000000001', 'Natural Graphite Anode Coating', 'renewable', '4GWh/yr', 2.6500);

INSERT INTO supplier_miner_details (supplier_id, mine_name, mining_method, extraction_volume, mine_coordinates, active_period_from) VALUES
('66333333-0000-4000-8000-000000000003', 'Balama Graphite Mine', 'open_pit', 35000.00, ST_SetSRID(ST_MakePoint(38.575, -13.348), 4326), '2018-01-01');

INSERT INTO factory_carbon_declarations (factory_id, carbon_intensity, methodology, declared_at, valid_from, source) VALUES
('76111111-0000-4000-8000-000000000001', 2.6500, 'PEF', '2024-05-01', '2024-05-01', 'third_party_verified'),
('76222222-0000-4000-8000-000000000002', 3.4200, 'PEF', '2024-05-01', '2024-05-01', 'supplier_declared');

INSERT INTO supplier_onboarding (supplier_id, consent_status, consent_signed_at, agreement_status, last_invited_at, sla_due_date, reminder_count) VALUES
('66111111-0000-4000-8000-000000000001', 'consent_agreed', now() - interval '18 days', 'agreed', now() - interval '19 days', now() - interval '5 days', 0),
('66222222-0000-4000-8000-000000000002', 'consent_agreed', now() - interval '14 days', 'agreed', now() - interval '15 days', now() - interval '1 days', 0),
('66333333-0000-4000-8000-000000000003', 'consent_agreed', now() - interval '12 days', 'agreed', now() - interval '13 days', now() + interval '1 days', 0);

INSERT INTO supplier_risk_profiles (supplier_id, overall_risk_score, risk_level, self_reported_risk_level, is_high_risk_flag, high_risk_reasons, last_risk_review_at) VALUES
('66111111-0000-4000-8000-000000000001', 11, 'low',    'low', FALSE, NULL, now() - interval '6 days'),
('66222222-0000-4000-8000-000000000002', 24, 'low',    'low', FALSE, NULL, now() - interval '6 days'),
('66333333-0000-4000-8000-000000000003', 45, 'medium', 'low', TRUE,  '["모잠비크 카보델가도 — 분쟁 인접(CAHRA) 지역"]'::jsonb, now() - interval '6 days');

-- IONIQ 6 BOM에 음극 품목 편성 (원가비중 합 100% 유지 — 모듈 45→33으로 조정)
UPDATE bom_items SET percentage = 33.00
WHERE bom_version_id = 'e7777777-0000-4000-8000-000000000007'
  AND part_id = 'b1111111-0000-4000-8000-000000000002';
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, direct_material_cost, origin_country, source_system, external_id) VALUES
('e7777777-0000-4000-8000-000000000007', 'b1111111-0000-4000-8000-000000000007', 26, 'kg', 7.00, 30.0000, 'KR', 'ERP_PLM', 'ERP-BI-I6-ANO'),
('e7777777-0000-4000-8000-000000000007', 'b1111111-0000-4000-8000-000000000014', 24, 'kg', 3.00, 14.0000, 'CN', 'ERP_PLM', 'ERP-BI-I6-PROCGR'),
('e7777777-0000-4000-8000-000000000007', 'b1111111-0000-4000-8000-000000000015', 30, 'kg', 2.00,  6.0000, 'MZ', 'ERP_PLM', 'ERP-BI-I6-MINGR');

-- 공급망 엣지 — 성진셀(hop1) 아래 음극 분기. 전부 verified(완주 유지).
INSERT INTO supply_chain_map (edge_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('87777777-0000-4000-8000-000000000007', 'e7777777-0000-4000-8000-000000000007', '61333333-0000-4000-8000-000000000003', '66111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000007', 2, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2024-01-01', '2024-12-31'),
('87777777-0000-4000-8000-000000000008', 'e7777777-0000-4000-8000-000000000007', '66111111-0000-4000-8000-000000000001', '66222222-0000-4000-8000-000000000002', 'b1111111-0000-4000-8000-000000000014', 3, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2024-01-01', '2024-12-31'),
('87777777-0000-4000-8000-000000000009', 'e7777777-0000-4000-8000-000000000007', '66222222-0000-4000-8000-000000000002', '66333333-0000-4000-8000-000000000003', 'b1111111-0000-4000-8000-000000000015', 4, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2024-01-01', '2024-12-31');

-- map_id 백필 (IONIQ 6 헤더는 16-9에서 이미 생성됨)
UPDATE supply_chain_map scm SET map_id = h.map_id
FROM supply_chain_maps h
WHERE h.bom_version_id = scm.bom_version_id AND scm.map_id IS NULL;

INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit) VALUES
('87777777-0000-4000-8000-000000000007', '76111111-0000-4000-8000-000000000001', 100.00, 9800, 'kg'),
('87777777-0000-4000-8000-000000000008', '76222222-0000-4000-8000-000000000002', 100.00, 9000, 'kg'),
('87777777-0000-4000-8000-000000000009', '76333333-0000-4000-8000-000000000003', 100.00, 11500, 'kg');

-- IONIQ 6 [미실행] EU向 배치 — 한국 OEM의 EU 수출 물량(규제 세트는 destination이 정함).
--   천연흑연 실사 스토리의 평가 대상. 데모에서 파이프라인 실행용으로 미실행(stage_queued) 유지.
--   ※ 제품(d7777777, 섹션 16-2) 생성 이후여야 FK 충족 — 섹션 12 배치 블록에 넣지 말 것.
INSERT INTO batches (batch_id, product_id, bom_version_id, tenant_id, destination, current_stage, status, confidence_score, source_system, external_id) VALUES
('ba777777-0000-4000-8000-000000000007', 'd7777777-0000-4000-8000-000000000007', 'e7777777-0000-4000-8000-000000000007', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'EU', 'stage_queued', 'batch_processing', NULL, 'MES', 'MES-LOT-I6');


-- ============================================================
-- 19. STEP3 발송 이력 백필 — 맵 진행도와 데이터 계약 이력 정합
-- ============================================================
-- 문제: supply_chain_map 엣지는 verified(=STEP4 수신 확인 완료)인데 그 협력사의
--   data_provision_consents/data_request_log(=STEP3 동의·자료요청 발송 이력)가 없어,
--   허브가 "발송한 적 없는데 수신 확인만 된" 모순 상태(step3 미완료·step4 완료)로 뜬다.
-- 규칙(허브 판정 로직과 동일 — SupplyChainHub의 consentTargets/mailed 기준):
--   · 대상 = 맵 편입(hop>0) 협력사, miner 제외(발송 대상 아님), 원청 제외
--   · verified 엣지 보유          → 'agreed'    (발송→회신→체결까지 완료)
--   · 완료 맵 편입 + verified 없음 → 'requested' (발송했고 회신 대기:
--     신성배터리(iX 보조 1차)·EQE/IONIQ5 4차 제련소·Unverified Trader)
--   · building 맵(VW ID.7)은 STEP1부터 밟는 시나리오 — 이력 없음 유지
-- 중복 방어: 협력사당 기존 이력 있으면 스킵(한양셀 agreed 샘플 등 보존) → 재실행 안전

-- A. verified(수신 확인 완료) 협력사 → 체결 완료(agreed) 동의서
INSERT INTO data_provision_consents
  (supplier_id, tenant_id, data_scope, purpose, third_party_sharing, allowed_recipients,
   valid_from, valid_to, revocable, status, requested_at, returned_at, agreed_at,
   signer_name, signer_title, signer_email, signature_method, form_version, form_data, agreement_hash)
SELECT DISTINCT ON (s.supplier_id)
  s.supplier_id, s.tenant_id,
  '["company","contacts","factories","carbon_epd","origin"]'::jsonb, 'EU_BATTERY', TRUE,
  CASE WHEN cu.customer_name IS NOT NULL THEN jsonb_build_array(cu.customer_name) END,
  '2026-01-01'::date, '2027-12-31'::date, TRUE, 'agreed',
  now() - interval '21 days', now() - interval '14 days', now() - interval '13 days',
  c.name, c.role, c.email, 'email_form', 'v1.0',
  jsonb_build_object('data_subject', s.company_name, 'sub_supplier_consent', true, 'retention_years', 7),
  substr(md5(s.supplier_id::text), 1, 12)
FROM suppliers s
JOIN supply_chain_map scm ON scm.child_supplier_id = s.supplier_id
  AND scm.hop_level > 0 AND scm.verification_status = 'verified'
JOIN bom_versions bv ON bv.bom_version_id = scm.bom_version_id
JOIN products p      ON p.product_id = bv.product_id
LEFT JOIN customers cu ON cu.customer_id = p.customer_id
LEFT JOIN supplier_contacts c ON c.supplier_id = s.supplier_id AND c.is_primary
WHERE s.provider_type <> 'miner'
  AND NOT EXISTS (SELECT 1 FROM data_provision_consents dc WHERE dc.supplier_id = s.supplier_id)
ORDER BY s.supplier_id, scm.hop_level;

-- B. 발송됐지만 미회신(requested) — 완료 맵 편입 + verified 엣지 전무
INSERT INTO data_provision_consents
  (supplier_id, tenant_id, data_scope, purpose, third_party_sharing, allowed_recipients,
   valid_from, valid_to, revocable, status, requested_at, form_version)
SELECT DISTINCT ON (s.supplier_id)
  s.supplier_id, s.tenant_id,
  '["company","contacts","factories","carbon_epd","origin"]'::jsonb, 'EU_BATTERY', TRUE,
  CASE WHEN cu.customer_name IS NOT NULL THEN jsonb_build_array(cu.customer_name) END,
  '2026-01-01'::date, '2027-12-31'::date, TRUE, 'requested',
  now() - interval '3 days', 'v1.0'
FROM suppliers s
JOIN supply_chain_map scm ON scm.child_supplier_id = s.supplier_id AND scm.hop_level > 0
JOIN supply_chain_maps h ON h.bom_version_id = scm.bom_version_id AND h.status = 'completed'
JOIN bom_versions bv ON bv.bom_version_id = scm.bom_version_id
JOIN products p      ON p.product_id = bv.product_id
LEFT JOIN customers cu ON cu.customer_id = p.customer_id
WHERE s.provider_type <> 'miner'
  AND NOT EXISTS (SELECT 1 FROM supply_chain_map v
                  WHERE v.child_supplier_id = s.supplier_id AND v.verification_status = 'verified')
  AND NOT EXISTS (SELECT 1 FROM data_provision_consents dc WHERE dc.supplier_id = s.supplier_id)
ORDER BY s.supplier_id, scm.hop_level;

-- C. 자료요청 대장(data_request_log) 백필 — A·B와 동일 대상, 협력사당 1건.
--    허브 createDataRequest와 동일한 requested_data_type('general_info').
INSERT INTO data_request_log
  (requester_user_id, target_supplier_id, requested_data_type, requested_at, due_date,
   response_status, submission_status)
SELECT
  '11111111-0000-4000-8000-000000000002', dc.supplier_id, 'general_info',
  dc.requested_at, dc.requested_at + interval '14 days',
  CASE WHEN dc.status = 'agreed' THEN 'response_responded' ELSE 'response_pending' END,
  CASE WHEN dc.status = 'agreed' THEN 'submission_approved' ELSE 'submission_requested' END
FROM data_provision_consents dc
WHERE NOT EXISTS (SELECT 1 FROM data_request_log dr WHERE dr.target_supplier_id = dc.supplier_id);


-- ============================================================
-- 26. [fan-out] 제련소 → 광산 다:다 보강
--   문제: 제련소(4차)마다 광산(5차)이 1:1이라 "제련소 밑 광산이 여러 개면 tier로
--         다 표시돼야 하는데 안 보임" + "제련소 다음 티어 광산" 표현 부족.
--   보강: ⑤~⑨ 제품의 제련소 5곳(64111111~64555555)에 형제 광산(5차)을 1개씩 추가
--         연결하고, 광산=mining 사업장(=광산 자체)과 좌표를 부여한다.
--   기존 블록은 수정하지 않고 이 섹션만 append. 멱등(ON CONFLICT / IN절 UPDATE).
-- ============================================================

-- 26-1. 형제 광산 supplier (miner)
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, ceo_name, provider_type, country, address, business_reg_doc_url, completeness_score, status, risk_level) VALUES
('d5000000-0000-4000-8000-000000000001', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Morowali Nickel Mine 2', 'Morowali Nickel Mine 2', 'Rudi Salim CEO',       'miner', 'ID', 'Sulawesi Tengah, Morowali Mining District B', NULL, 32, 'supplier_review',      'medium'),
('d6000000-0000-4000-8000-000000000002', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Obi Island Nickel Mine', 'Obi Island Nickel Mine', 'Hendra Gunawan CEO',  'miner', 'ID', 'North Maluku, Obi Island Mining Zone',        NULL, 30, 'supplier_in_progress', 'medium'),
('d7000000-0000-4000-8000-000000000003', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Mt Keith Nickel Mine',   'Mt Keith Nickel Mine',   'David Brown CEO',     'miner', 'AU', 'Western Australia, Mt Keith Mining District', 's3://kira-docs/suppliers/d7000000/biz_reg.pdf', 66, 'supplier_verified', 'low'),
('d8000000-0000-4000-8000-000000000004', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Kolwezi Cobalt Mine',    'Kolwezi Cobalt Mine',    'Jean-Pierre Mbaya CEO','miner', 'CD', 'Lualaba Province, Kolwezi Mining Zone',       NULL, 25, 'supplier_review',      'high'),
('d9000000-0000-4000-8000-000000000005', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Barro Alto Nickel Mine', 'Barro Alto Nickel Mine', 'Ricardo Souza CEO',   'miner', 'BR', 'Goiás State, Barro Alto Mining District',     's3://kira-docs/suppliers/d9000000/biz_reg.pdf', 64, 'supplier_verified', 'low')
ON CONFLICT (supplier_id) DO NOTHING;

-- 26-2. 광산 사업장 (factory_role='mining' — 광산이 곧 사업장)
INSERT INTO supplier_factories (factory_id, supplier_id, factory_name, factory_name_en, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent) VALUES
('7d000000-0000-4000-8000-000000000001', 'd5000000-0000-4000-8000-000000000001', 'Morowali Nickel Mine B', 'Morowali Nickel Mine B', 'ID', 'Sulawesi',          ST_SetSRID(ST_MakePoint(121.800, -2.100), 4326),  'mining', 'BOTH', '["CRMA","CONFLICT_MINERALS","EUDR"]'::jsonb, 100.00),
('7d000000-0000-4000-8000-000000000002', 'd6000000-0000-4000-8000-000000000002', 'Obi Island Mine',        'Obi Island Mine',        'ID', 'North Maluku',      ST_SetSRID(ST_MakePoint(127.550, -1.550), 4326),  'mining', 'BOTH', '["CRMA","EUDR"]'::jsonb, 100.00),
('7d000000-0000-4000-8000-000000000003', 'd7000000-0000-4000-8000-000000000003', 'Mt Keith Nickel Mine',   'Mt Keith Nickel Mine',   'AU', 'Western Australia', ST_SetSRID(ST_MakePoint(120.550, -27.250), 4326), 'mining', 'BOTH', '["CRMA"]'::jsonb, 100.00),
('7d000000-0000-4000-8000-000000000004', 'd8000000-0000-4000-8000-000000000004', 'Kolwezi Cobalt Mine',    'Kolwezi Cobalt Mine',    'CD', 'Lualaba',           ST_SetSRID(ST_MakePoint(25.470, -10.720), 4326),  'mining', 'EU',   '["CONFLICT_MINERALS","CRMA"]'::jsonb, 100.00),
('7d000000-0000-4000-8000-000000000005', 'd9000000-0000-4000-8000-000000000005', 'Barro Alto Nickel Mine', 'Barro Alto Nickel Mine', 'BR', 'Goias',             ST_SetSRID(ST_MakePoint(-48.920, -14.970), 4326), 'mining', 'BOTH', '["CRMA"]'::jsonb, 100.00)
ON CONFLICT (factory_id) DO NOTHING;

-- 26-3. 광산 상세(좌표)
INSERT INTO supplier_miner_details (supplier_id, mine_name, mining_method, extraction_volume, mine_coordinates, active_period_from) VALUES
('d5000000-0000-4000-8000-000000000001', 'Morowali Nickel Mine B', 'open_pit', 30000.00, ST_SetSRID(ST_MakePoint(121.800, -2.100), 4326),  '2021-01-01'),
('d6000000-0000-4000-8000-000000000002', 'Obi Island Nickel Mine', 'open_pit', 28000.00, ST_SetSRID(ST_MakePoint(127.550, -1.550), 4326),  '2020-01-01'),
('d7000000-0000-4000-8000-000000000003', 'Mt Keith Nickel Mine',   'open_pit', 35000.00, ST_SetSRID(ST_MakePoint(120.550, -27.250), 4326), '2016-01-01'),
('d8000000-0000-4000-8000-000000000004', 'Kolwezi Cobalt Mine',    'open_pit', 22000.00, ST_SetSRID(ST_MakePoint(25.470, -10.720), 4326),  '2018-01-01'),
('d9000000-0000-4000-8000-000000000005', 'Barro Alto Nickel Mine', 'open_pit', 33000.00, ST_SetSRID(ST_MakePoint(-48.920, -14.970), 4326), '2017-01-01');

-- 26-4. 형제 광산 엣지(hop_level=5) — 각 제련소 하위에 광산 추가 연결
INSERT INTO supply_chain_map (edge_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('da555555-0000-4000-8000-000000000001', 'e5555555-0000-4000-8000-000000000005', '64111111-0000-4000-8000-000000000001', 'd5000000-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000008', 5, 'supplychain_declared',  'SUPPLIER_DECLARED', 'unverified', '2024-07-01', '2025-06-30'),
('da666666-0000-4000-8000-000000000002', 'e6666666-0000-4000-8000-000000000006', '64222222-0000-4000-8000-000000000002', 'd6000000-0000-4000-8000-000000000002', 'b1111111-0000-4000-8000-000000000008', 5, 'supplychain_declared',  'SUPPLIER_DECLARED', 'unverified', '2024-04-01', '2025-03-31'),
('da777777-0000-4000-8000-000000000003', 'e7777777-0000-4000-8000-000000000007', '64333333-0000-4000-8000-000000000003', 'd7000000-0000-4000-8000-000000000003', 'b1111111-0000-4000-8000-000000000008', 5, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified',   '2024-01-01', '2024-12-31'),
('da888888-0000-4000-8000-000000000004', 'e8888888-0000-4000-8000-000000000008', '64444444-0000-4000-8000-000000000004', 'd8000000-0000-4000-8000-000000000004', 'b1111111-0000-4000-8000-000000000009', 5, 'supplychain_declared',  'SUPPLIER_DECLARED', 'unverified', '2024-03-01', '2025-02-28'),
('da999999-0000-4000-8000-000000000005', 'e9999999-0000-4000-8000-000000000009', '64555555-0000-4000-8000-000000000005', 'd9000000-0000-4000-8000-000000000005', 'b1111111-0000-4000-8000-000000000008', 5, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified',   '2024-06-01', '2024-12-31')
ON CONFLICT (edge_id) DO NOTHING;

-- 26-5. 새 엣지 map_id 백필(소속 맵 헤더 연결)
UPDATE supply_chain_map scm SET map_id = h.map_id
FROM supply_chain_maps h
WHERE h.bom_version_id = scm.bom_version_id AND scm.map_id IS NULL;

-- 26-6. 공급비율 — 기존 광산 60% + 형제 광산 40% (합 100)
UPDATE supply_ratio SET ratio_percentage = 60.00 WHERE edge_id IN (
  '85555555-0000-4000-8000-000000000007',
  '86666666-0000-4000-8000-000000000006',
  '87777777-0000-4000-8000-000000000006',
  '88888888-0000-4000-8000-000000000006',
  '89999999-0000-4000-8000-000000000006'
);
INSERT INTO supply_ratio (edge_id, factory_id, ratio_percentage, volume, unit) VALUES
('da555555-0000-4000-8000-000000000001', '7d000000-0000-4000-8000-000000000001', 40.00, 16800, 'kg'),
('da666666-0000-4000-8000-000000000002', '7d000000-0000-4000-8000-000000000002', 40.00, 16800, 'kg'),
('da777777-0000-4000-8000-000000000003', '7d000000-0000-4000-8000-000000000003', 40.00, 16800, 'kg'),
('da888888-0000-4000-8000-000000000004', '7d000000-0000-4000-8000-000000000004', 40.00,  8000, 'kg'),
('da999999-0000-4000-8000-000000000005', '7d000000-0000-4000-8000-000000000005', 40.00, 16800, 'kg');


-- ============================================================
-- 27. 광산/사업장 데이터 정합 (PM 지적) — 전부 멱등(idempotent), append 전용
--   ① 사업장 원산지 주소(supplier_factories.address) 백필: 좌표·region만 있고 텍스트 주소가
--      전부 NULL이라 '위치(원산지)' 표시가 공란이던 것 보완. 국내='region, 대한민국', 해외='region, Country'.
--      (상세 지번은 데모 범위 밖 — Geo audit SSOT는 location 좌표. 회사주소 suppliers.address와 별개.)
--   ② 광산(mining) 사업장 '공장 담당자' 제거: 광산은 자체 입력 주체가 아니라 제련소(직상위)가
--      원산지·광물을 대신 제공하는 구조 → 광산 사업장에 factory_manager가 붙는 건 모델상 부정합.
--   (리튬 광산 회사값 core_minerals 99.x→2.8 정정은 위 섹션 19-1 원본 라인에서 인라인 수정함.)
-- ============================================================

-- ① 원산지 주소 백필 (address가 비어있는 전체 사업장)
UPDATE supplier_factories
SET address = region || ', ' || CASE country
    WHEN 'KR' THEN '대한민국'
    WHEN 'CN' THEN 'China'
    WHEN 'ID' THEN 'Indonesia'
    WHEN 'AU' THEN 'Australia'
    WHEN 'CL' THEN 'Chile'
    WHEN 'ZM' THEN 'Zambia'
    WHEN 'BR' THEN 'Brazil'
    WHEN 'MZ' THEN 'Mozambique'
    ELSE country
  END
WHERE address IS NULL AND region IS NOT NULL;

-- ② 광산 사업장 공장 담당자 제거 (입력 주체 아님 — 제련소가 대신 제공)
UPDATE supplier_factories
SET factory_manager_name  = NULL,
    factory_manager_role  = NULL,
    factory_manager_phone = NULL,
    factory_manager_email = NULL
WHERE factory_role = 'mining';

-- ③ 광산 완성도 행 시드: 광산은 입력 주체가 아니라 required=0 → 100%('해당 없음'). 저장 행이
--    없으면 프론트가 폴백 경로로 regulation/documents를 오탐 '미입력'으로 표시하므로, 명시적으로
--    required=0 행을 넣어 '해당 없음'으로 렌더되게 한다. (백엔드 get_completeness도 행 없을 때
--    즉시계산하도록 보강했으나, 그 배포 전에도 재시드만으로 맞게 뜨도록 데이터로도 보장.)
--    (entity_type,entity_id) 유니크 제약이 없어 NOT EXISTS로 멱등 처리.
INSERT INTO data_completeness_status
  (entity_type, entity_id, required_field_count, filled_field_count, completion_rate, missing_fields)
SELECT 'supplier', s.supplier_id, 0, 0, 100.00, '[]'::jsonb
FROM suppliers s
WHERE s.provider_type = 'miner'
  AND NOT EXISTS (
    SELECT 1 FROM data_completeness_status d
    WHERE d.entity_type = 'supplier' AND d.entity_id = s.supplier_id
  );


-- ============================================================
-- 28. iX3(e1111111) 풀트리 레퍼런스 — Cell 밑을 양극+음극 전 갈래로 완성 (PM 요청)
--   기존 iX3는 리튬 단일 말단(CAM→한중제련 LiOH→호주리튬)만 있었다. 이 제품 하나를 표준
--   레퍼런스로 삼아 부품트리(parts) 구조 그대로 supplier 체인을 펼친다. 기존 엣지는 건드리지
--   않고 아래 가지만 append(멱등: 엣지 PK / supplier PK / NOT EXISTS).
--     · 양극: CAM(동성) →(신규)→ 전구체(동신) → REF-NI/CO/MN(제련) → Ni/Co/Mn 광산
--       (리튬 가지 CAM→LiOH→Li광산은 기존 유지 — CAM의 두 입력 = 전구체 + LiOH)
--     · 음극: Cell(한양셀) → ANO(한빛음극재) → 구형화(Qingdao) → 천연흑연광(Balama)
--   망간(Mn) 제련·광산 노드는 미존재라 신설. 나머지(전구체·Ni/Co 제련·광산·흑연체인)는 재사용.
--   엣지 core_minerals = 그 엣지에 흐르는 부품의 원소 질량%(제련=정제염 함량, 광산=원광 등급).
-- ============================================================

-- 28-1. 신규 망간(Mn) 제련소 + 광산 (기존에 Mn 노드 부재 — 트리 완성용)
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, ceo_name, provider_type, core_minerals, country, address, business_reg_doc_url, environmental_report_url, completeness_score, status, risk_level) VALUES
('64666666-0000-4000-8000-000000000006', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Xiangtan Mn Refinery', 'Xiangtan Mn Refinery', 'Zhao Lei CEO', 'smelter', '{"Mn":32.5}'::jsonb, 'CN', 'Hunan, Xiangtan Manganese Industrial Zone, China', 's3://kira-docs/suppliers/64666666/biz_reg.pdf', NULL, 74, 'supplier_verified', 'low'),
('65666666-0000-4000-8000-000000000006', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Kalahari Manganese Mine', 'Kalahari Manganese Mine', 'Pieter Botha CEO', 'miner', '{"Mn":38.0}'::jsonb, 'ZA', 'Northern Cape, Kalahari Manganese Field, South Africa', 's3://kira-docs/suppliers/65666666/biz_reg.pdf', NULL, 60, 'supplier_verified', 'low')
ON CONFLICT (supplier_id) DO NOTHING;
UPDATE suppliers SET smelter_type = 'private' WHERE supplier_id = '64666666-0000-4000-8000-000000000006';

-- 신규 사업장 (address 인라인 — 섹션 27 백필은 이 뒤 신설분을 못 잡으므로 직접 채움)
INSERT INTO supplier_factories (factory_id, supplier_id, factory_name, factory_name_en, address, country, region, location, factory_role, destination, applicable_regulations, supply_ratio_percent) VALUES
('74666666-0000-4000-8000-000000000006', '64666666-0000-4000-8000-000000000006', 'Xiangtan Mn Refinery', 'Xiangtan Mn Refinery', 'Xiangtan, Hunan, China', 'CN', 'Hunan', ST_SetSRID(ST_MakePoint(112.944, 27.829), 4326), 'processing', 'BOTH', '["CRMA","CBAM"]'::jsonb, 100.00),
('75666666-0000-4000-8000-000000000006', '65666666-0000-4000-8000-000000000006', 'Kalahari Manganese Mine', 'Kalahari Manganese Mine', 'Hotazel, Northern Cape, South Africa', 'ZA', 'Northern Cape', ST_SetSRID(ST_MakePoint(22.960, -27.220), 4326), 'mining', 'BOTH', '["CRMA","EUDR"]'::jsonb, 100.00)
ON CONFLICT (factory_id) DO NOTHING;

INSERT INTO supplier_miner_details (supplier_id, mine_name, mining_method, extraction_volume, mine_coordinates, active_period_from)
SELECT '65666666-0000-4000-8000-000000000006', 'Kalahari Manganese Mine', 'open_pit', 55000.00, ST_SetSRID(ST_MakePoint(22.960, -27.220), 4326), '2015-01-01'
WHERE NOT EXISTS (SELECT 1 FROM supplier_miner_details WHERE supplier_id = '65666666-0000-4000-8000-000000000006');

-- Mn 광산 완성도 행(입력 주체 아님 → required=0/100%). 섹션 27 ③은 이 신설 광산을 못 잡으므로 여기서.
INSERT INTO data_completeness_status (entity_type, entity_id, required_field_count, filled_field_count, completion_rate, missing_fields)
SELECT 'supplier', '65666666-0000-4000-8000-000000000006', 0, 0, 100.00, '[]'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM data_completeness_status d WHERE d.entity_type='supplier' AND d.entity_id='65666666-0000-4000-8000-000000000006');

-- 28-2. iX3 트리 엣지 append (양극 전구체 가지 + 음극 흑연 가지)
INSERT INTO supply_chain_map (edge_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
-- [양극] CAM(동성) → 전구체(동신) → Ni/Co/Mn 제련 → 광산
('5b111111-0000-4000-8000-000000000001', 'e1111111-0000-4000-8000-000000000001', 'a2222222-2222-4000-8000-000000000002', '63111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000004', 4, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
('5b111111-0000-4000-8000-000000000002', 'e1111111-0000-4000-8000-000000000001', '63111111-0000-4000-8000-000000000001', '64333333-0000-4000-8000-000000000003', 'b1111111-0000-4000-8000-000000000011', 5, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
('5b111111-0000-4000-8000-000000000003', 'e1111111-0000-4000-8000-000000000001', '64333333-0000-4000-8000-000000000003', '65333333-0000-4000-8000-000000000003', 'b1111111-0000-4000-8000-000000000008', 6, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
('5b111111-0000-4000-8000-000000000004', 'e1111111-0000-4000-8000-000000000001', '63111111-0000-4000-8000-000000000001', '64444444-0000-4000-8000-000000000004', 'b1111111-0000-4000-8000-000000000012', 5, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
('5b111111-0000-4000-8000-000000000005', 'e1111111-0000-4000-8000-000000000001', '64444444-0000-4000-8000-000000000004', '65444444-0000-4000-8000-000000000004', 'b1111111-0000-4000-8000-000000000009', 6, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
('5b111111-0000-4000-8000-000000000006', 'e1111111-0000-4000-8000-000000000001', '63111111-0000-4000-8000-000000000001', '64666666-0000-4000-8000-000000000006', 'b1111111-0000-4000-8000-000000000013', 5, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
('5b111111-0000-4000-8000-000000000007', 'e1111111-0000-4000-8000-000000000001', '64666666-0000-4000-8000-000000000006', '65666666-0000-4000-8000-000000000006', 'b1111111-0000-4000-8000-00000000000a', 6, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
-- [음극] Cell(한양셀) → ANO(한빛음극재) → 구형화(Qingdao) → 천연흑연광(Balama)
('5b111111-0000-4000-8000-000000000008', 'e1111111-0000-4000-8000-000000000001', 'a1111111-1111-4000-8000-000000000001', '66111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000007', 3, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
('5b111111-0000-4000-8000-000000000009', 'e1111111-0000-4000-8000-000000000001', '66111111-0000-4000-8000-000000000001', '66222222-0000-4000-8000-000000000002', 'b1111111-0000-4000-8000-000000000014', 4, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31'),
('5b111111-0000-4000-8000-00000000000a', 'e1111111-0000-4000-8000-000000000001', '66222222-0000-4000-8000-000000000002', '66333333-0000-4000-8000-000000000003', 'b1111111-0000-4000-8000-000000000015', 5, 'supplychain_confirmed', 'SUPPLIER_DECLARED', 'verified', '2025-01-01', '2025-12-31')
ON CONFLICT (edge_id) DO NOTHING;

-- 28-3. 엣지 core_minerals(원소 질량%) — 부품별
UPDATE supply_chain_map SET core_minerals = '{"Ni":50.8,"Co":6.4,"Mn":5.9}'::jsonb WHERE edge_id = '5b111111-0000-4000-8000-000000000001'; -- PRE-NCM(전구체 수산화물)
UPDATE supply_chain_map SET core_minerals = '{"Ni":22.3}'::jsonb WHERE edge_id = '5b111111-0000-4000-8000-000000000002'; -- REF-NI(황산니켈)
UPDATE supply_chain_map SET core_minerals = '{"Ni":1.8}'::jsonb  WHERE edge_id = '5b111111-0000-4000-8000-000000000003'; -- MIN-NI(니켈 라테라이트 원광)
UPDATE supply_chain_map SET core_minerals = '{"Co":20.9}'::jsonb WHERE edge_id = '5b111111-0000-4000-8000-000000000004'; -- REF-CO(황산코발트)
UPDATE supply_chain_map SET core_minerals = '{"Co":2.5}'::jsonb  WHERE edge_id = '5b111111-0000-4000-8000-000000000005'; -- MIN-CO(코발트 원광)
UPDATE supply_chain_map SET core_minerals = '{"Mn":32.5}'::jsonb WHERE edge_id = '5b111111-0000-4000-8000-000000000006'; -- REF-MN(황산망간)
UPDATE supply_chain_map SET core_minerals = '{"Mn":38.0}'::jsonb WHERE edge_id = '5b111111-0000-4000-8000-000000000007'; -- MIN-MN(망간 원광)
UPDATE supply_chain_map SET core_minerals = '{"graphite_natural":95.0}'::jsonb  WHERE edge_id = '5b111111-0000-4000-8000-000000000008'; -- ANO-GRAPHITE(음극활물질)
UPDATE supply_chain_map SET core_minerals = '{"graphite_natural":99.95}'::jsonb WHERE edge_id = '5b111111-0000-4000-8000-000000000009'; -- PROC-GRAPHITE(구형화 정제)
UPDATE supply_chain_map SET core_minerals = '{"graphite_natural":10.0}'::jsonb  WHERE edge_id = '5b111111-0000-4000-8000-00000000000a'; -- MIN-GRAPHITE(천연흑연 원광)

-- 28-4. 동의서/자료요청 백필 재실행(섹션 27과 동일 로직) — 섹션 28에서 새로 추가된 협력사/엣지
--   (Xiangtan Mn Refinery 등)는 섹션 27의 백필보다 파일에서 뒤에 있어 그때는 안 잡혔다.
--   같은 NOT EXISTS 가드라 이미 이력 있는 협력사는 건드리지 않고(멱등), 이번에 새로
--   verified/편입된 협력사만 채운다.
INSERT INTO data_provision_consents
  (supplier_id, tenant_id, data_scope, purpose, third_party_sharing, allowed_recipients,
   valid_from, valid_to, revocable, status, requested_at, returned_at, agreed_at,
   signer_name, signer_title, signer_email, signature_method, form_version, form_data, agreement_hash)
SELECT DISTINCT ON (s.supplier_id)
  s.supplier_id, s.tenant_id,
  '["company","contacts","factories","carbon_epd","origin"]'::jsonb, 'EU_BATTERY', TRUE,
  CASE WHEN cu.customer_name IS NOT NULL THEN jsonb_build_array(cu.customer_name) END,
  '2026-01-01'::date, '2027-12-31'::date, TRUE, 'agreed',
  now() - interval '21 days', now() - interval '14 days', now() - interval '13 days',
  c.name, c.role, c.email, 'email_form', 'v1.0',
  jsonb_build_object('data_subject', s.company_name, 'sub_supplier_consent', true, 'retention_years', 7),
  substr(md5(s.supplier_id::text), 1, 12)
FROM suppliers s
JOIN supply_chain_map scm ON scm.child_supplier_id = s.supplier_id
  AND scm.hop_level > 0 AND scm.verification_status = 'verified'
JOIN bom_versions bv ON bv.bom_version_id = scm.bom_version_id
JOIN products p      ON p.product_id = bv.product_id
LEFT JOIN customers cu ON cu.customer_id = p.customer_id
LEFT JOIN supplier_contacts c ON c.supplier_id = s.supplier_id AND c.is_primary
WHERE s.provider_type <> 'miner'
  AND NOT EXISTS (SELECT 1 FROM data_provision_consents dc WHERE dc.supplier_id = s.supplier_id)
ORDER BY s.supplier_id, scm.hop_level;

INSERT INTO data_provision_consents
  (supplier_id, tenant_id, data_scope, purpose, third_party_sharing, allowed_recipients,
   valid_from, valid_to, revocable, status, requested_at, form_version)
SELECT DISTINCT ON (s.supplier_id)
  s.supplier_id, s.tenant_id,
  '["company","contacts","factories","carbon_epd","origin"]'::jsonb, 'EU_BATTERY', TRUE,
  CASE WHEN cu.customer_name IS NOT NULL THEN jsonb_build_array(cu.customer_name) END,
  '2026-01-01'::date, '2027-12-31'::date, TRUE, 'requested',
  now() - interval '3 days', 'v1.0'
FROM suppliers s
JOIN supply_chain_map scm ON scm.child_supplier_id = s.supplier_id AND scm.hop_level > 0
JOIN supply_chain_maps h ON h.bom_version_id = scm.bom_version_id AND h.status = 'completed'
JOIN bom_versions bv ON bv.bom_version_id = scm.bom_version_id
JOIN products p      ON p.product_id = bv.product_id
LEFT JOIN customers cu ON cu.customer_id = p.customer_id
WHERE s.provider_type <> 'miner'
  AND NOT EXISTS (SELECT 1 FROM supply_chain_map v
                  WHERE v.child_supplier_id = s.supplier_id AND v.verification_status = 'verified')
  AND NOT EXISTS (SELECT 1 FROM data_provision_consents dc WHERE dc.supplier_id = s.supplier_id)
ORDER BY s.supplier_id, scm.hop_level;

-- 28-5. 승격 — 섹션 28 이전에 이미 'requested'로 백필된 협력사(예: Zambia Copper & Cobalt
--   Refinery)가 섹션 28에서 새로 verified 엣지를 얻은 경우, 위 두 INSERT는 NOT EXISTS 가드 때문에
--   건드리지 않는다. verified 엣지가 실제로 있는데 동의서는 여전히 'requested'로 멈춰있는
--   협력사만 골라 'agreed'로 승격한다(동의서 상태가 실제 엣지 상태를 반영하도록).
UPDATE data_provision_consents dc SET
  status = 'agreed',
  returned_at = COALESCE(dc.returned_at, now() - interval '14 days'),
  agreed_at   = COALESCE(dc.agreed_at, now() - interval '13 days')
WHERE dc.status = 'requested'
  AND EXISTS (
    SELECT 1 FROM supply_chain_map v
    WHERE v.child_supplier_id = dc.supplier_id AND v.verification_status = 'verified'
  );

INSERT INTO data_request_log
  (requester_user_id, target_supplier_id, requested_data_type, requested_at, due_date,
   response_status, submission_status)
SELECT
  NULL, dc.supplier_id, 'general_info', dc.requested_at, dc.requested_at + interval '14 days',
  CASE WHEN dc.status = 'agreed' THEN 'response_responded' ELSE 'response_pending' END,
  CASE WHEN dc.status = 'agreed' THEN 'submission_approved' ELSE 'submission_requested' END
FROM data_provision_consents dc
WHERE NOT EXISTS (SELECT 1 FROM data_request_log dr WHERE dr.target_supplier_id = dc.supplier_id);

-- 28-5 승격과 짝 — 이미 있던 data_request_log 행도 'agreed' 승격에 맞춰 같이 갱신.
UPDATE data_request_log dr SET
  response_status = 'response_responded',
  submission_status = 'submission_approved'
FROM data_provision_consents dc
WHERE dr.target_supplier_id = dc.supplier_id
  AND dc.status = 'agreed'
  AND dr.response_status <> 'response_responded';


-- ============================================================
-- 29. PM테스트협력사01~10 전용 테스트 Ingest 번들
-- ============================================================
-- 목적: PM테스트협력사01~10(기존 ID 그대로)을 1차 협력사로 정식 연결한 전용 테스트
--   제품+BOM+공급망 맵을 새로 만든다. 제품명은 다른 제품과 겹쳐도 무방(요청 확인됨),
--   BOM 버전명만 다른 제품과 안 헷갈리게 TEST- 접두어로 구분한다.

-- 29-1. 신규 부품 2개(루트 Pack + 1차 공통 부품)
INSERT INTO parts (part_id, part_code, part_name, tier_level, parent_part_id, material_type, source_system, external_id) VALUES
('bf000000-0000-4000-8000-000000000001', 'PM-TEST-PACK', 'PM Test Pack',      0, NULL, 'assembly', 'MANUAL_TEST', 'PM-TEST-PART-PACK'),
('bf000000-0000-4000-8000-000000000002', 'PM-TEST-COMP', 'PM Test Component', 1, 'bf000000-0000-4000-8000-000000000001', 'component', 'MANUAL_TEST', 'PM-TEST-PART-COMP')
ON CONFLICT (part_id) DO NOTHING;

-- 29-2. 신규 제품
INSERT INTO products (product_id, product_code, product_name, manufacturer_id, tenant_id, customer_id, model_name, amperage_ah, type, source_system, external_id) VALUES
('bf100000-0000-4000-8000-000000000001', 'PM-TEST-BATT-01', 'PM테스트 배터리팩', 'a0000000-0000-4000-8000-000000000000', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'c0000000-0000-4000-8000-0000000000b4', 'PM Test', 100.00, 'battery_pack', 'MANUAL_TEST', 'PM-TEST-PRODUCT')
ON CONFLICT (product_id) DO NOTHING;

-- 29-3. BOM 버전
INSERT INTO bom_versions (bom_version_id, product_id, version_number, production_from, production_to, status, source_system, external_id) VALUES
('bf200000-0000-4000-8000-000000000001', 'bf100000-0000-4000-8000-000000000001', 'TEST-v1.0', '2026-07-06', '2027-07-06', 'active', 'MANUAL_TEST', 'PM-TEST-BOM')
ON CONFLICT (bom_version_id) DO NOTHING;

-- 29-4. BOM 항목(루트 Pack 100% + 1차 공통부품 100%)
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, origin_country, source_system, external_id) VALUES
('bf200000-0000-4000-8000-000000000001', 'bf000000-0000-4000-8000-000000000001', 1, 'ea', 100.00, 'KR', 'MANUAL_TEST', 'PM-TEST-BI-PACK'),
('bf200000-0000-4000-8000-000000000001', 'bf000000-0000-4000-8000-000000000002', 10, 'ea', 100.00, 'KR', 'MANUAL_TEST', 'PM-TEST-BI-COMP');

-- 29-5. 공급망 맵 헤더(building — PM님이 STEP2부터 진행하는 시나리오)
INSERT INTO supply_chain_maps (map_id, bom_version_id, product_id, status) VALUES
('bf300000-0000-4000-8000-000000000001', 'bf200000-0000-4000-8000-000000000001', 'bf100000-0000-4000-8000-000000000001', 'building')
ON CONFLICT (bom_version_id) DO NOTHING;

-- 29-6. hop0 앵커(원청 KIRA)
INSERT INTO supply_chain_map (edge_id, map_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('bf400000-0000-4000-8000-000000000000', 'bf300000-0000-4000-8000-000000000001', 'bf200000-0000-4000-8000-000000000001', NULL, 'a0000000-0000-4000-8000-000000000000', 'bf000000-0000-4000-8000-000000000001', 0, 'supplychain_confirmed', 'ERP', 'unverified', '2026-07-06', '2027-07-06');

-- 29-7. hop1 — PM테스트협력사01~10, 전부 원청(KIRA) 직속 1차로 연결
INSERT INTO supply_chain_map (edge_id, map_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to)
SELECT uuid_generate_v4(), 'bf300000-0000-4000-8000-000000000001', 'bf200000-0000-4000-8000-000000000001',
       'a0000000-0000-4000-8000-000000000000', s.supplier_id, 'bf000000-0000-4000-8000-000000000002', 1,
       'supplychain_declared', 'ERP', 'unverified', '2026-07-06', '2027-07-06'
FROM suppliers s
WHERE s.company_name LIKE 'PM테스트협력사%'
  AND NOT EXISTS (
    SELECT 1 FROM supply_chain_map scm
    WHERE scm.bom_version_id = 'bf200000-0000-4000-8000-000000000001' AND scm.child_supplier_id = s.supplier_id
  );


-- ============================================================
-- 30. PM테스트 번들 — 유형별 현실적 Tier 재배치
-- ============================================================
-- 문제: 29번에서 10곳을 전부 Tier1(원청 직속)로 뭉쳐 연결해서, 광산이 1차 협력사로
--   뜨는 등 도메인상 말이 안 되는 구조였다. 제조사(1~3차)→유통(3차, 트레이딩)→
--   제련소(4차)→광산(5차) 순서의 2개 평행 체인으로 재배치한다.

-- 30-1. 기존 Tier1 연결 전부 제거(29번에서 만든 것)
DELETE FROM supply_chain_map
WHERE bom_version_id = 'bf200000-0000-4000-8000-000000000001' AND hop_level > 0;

-- 30-2. 티어별 부품 추가(2~5차) — 1차 부품(PM Test Component)은 29번 것 재사용
INSERT INTO parts (part_id, part_code, part_name, tier_level, parent_part_id, material_type, source_system, external_id) VALUES
('bf000000-0000-4000-8000-000000000003', 'PM-TEST-CAM',  'PM Test CAM',          2, 'bf000000-0000-4000-8000-000000000002', 'active_material', 'MANUAL_TEST', 'PM-TEST-PART-CAM'),
('bf000000-0000-4000-8000-000000000004', 'PM-TEST-DIST', 'PM Test Distribution', 3, 'bf000000-0000-4000-8000-000000000003', 'trading',         'MANUAL_TEST', 'PM-TEST-PART-DIST'),
('bf000000-0000-4000-8000-000000000005', 'PM-TEST-REF',  'PM Test Refined Material', 4, 'bf000000-0000-4000-8000-000000000004', 'refined_metal', 'MANUAL_TEST', 'PM-TEST-PART-REF'),
('bf000000-0000-4000-8000-000000000006', 'PM-TEST-ORE',  'PM Test Ore',          5, 'bf000000-0000-4000-8000-000000000005', 'mineral',         'MANUAL_TEST', 'PM-TEST-PART-ORE')
ON CONFLICT (part_id) DO NOTHING;

-- 30-3. BOM 항목 추가(신규 부품 4개)
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, origin_country, source_system, external_id) VALUES
('bf200000-0000-4000-8000-000000000001', 'bf000000-0000-4000-8000-000000000003', 10, 'kg', 100.00, 'KR', 'MANUAL_TEST', 'PM-TEST-BI-CAM'),
('bf200000-0000-4000-8000-000000000001', 'bf000000-0000-4000-8000-000000000004', 10, 'kg', 100.00, 'KR', 'MANUAL_TEST', 'PM-TEST-BI-DIST'),
('bf200000-0000-4000-8000-000000000001', 'bf000000-0000-4000-8000-000000000005', 10, 'kg', 100.00, 'KR', 'MANUAL_TEST', 'PM-TEST-BI-REF'),
('bf200000-0000-4000-8000-000000000001', 'bf000000-0000-4000-8000-000000000006', 10, 'kg', 100.00, 'KR', 'MANUAL_TEST', 'PM-TEST-BI-ORE')
ON CONFLICT DO NOTHING;

-- 30-4. 체인 A: 01(제조사,1차) → 02(제조사,2차) → 09(유통,3차) → 07(제련소,4차) → 05(광산,5차)
INSERT INTO supply_chain_map (edge_id, map_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
(uuid_generate_v4(), 'bf300000-0000-4000-8000-000000000001', 'bf200000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000000', '71000001-0000-4000-8000-000000000001', 'bf000000-0000-4000-8000-000000000002', 1, 'supplychain_declared', 'ERP', 'unverified', '2026-07-06', '2027-07-06'),
(uuid_generate_v4(), 'bf300000-0000-4000-8000-000000000001', 'bf200000-0000-4000-8000-000000000001', '71000001-0000-4000-8000-000000000001', '71000002-0000-4000-8000-000000000002', 'bf000000-0000-4000-8000-000000000003', 2, 'supplychain_declared', 'SUPPLIER_DECLARED', 'unverified', '2026-07-06', '2027-07-06'),
(uuid_generate_v4(), 'bf300000-0000-4000-8000-000000000001', 'bf200000-0000-4000-8000-000000000001', '71000002-0000-4000-8000-000000000002', '71000009-0000-4000-8000-000000000009', 'bf000000-0000-4000-8000-000000000004', 3, 'supplychain_declared', 'SUPPLIER_DECLARED', 'unverified', '2026-07-06', '2027-07-06'),
(uuid_generate_v4(), 'bf300000-0000-4000-8000-000000000001', 'bf200000-0000-4000-8000-000000000001', '71000009-0000-4000-8000-000000000009', '71000007-0000-4000-8000-000000000007', 'bf000000-0000-4000-8000-000000000005', 4, 'supplychain_declared', 'SUPPLIER_DECLARED', 'unverified', '2026-07-06', '2027-07-06'),
(uuid_generate_v4(), 'bf300000-0000-4000-8000-000000000001', 'bf200000-0000-4000-8000-000000000001', '71000007-0000-4000-8000-000000000007', '71000005-0000-4000-8000-000000000005', 'bf000000-0000-4000-8000-000000000006', 5, 'supplychain_declared', 'SUPPLIER_DECLARED', 'unverified', '2026-07-06', '2027-07-06');

-- 30-5. 체인 B: 04(제조사,1차) → 03(제조사,2차) → 10(유통,3차) → 08(제련소,4차) → 06(광산,5차)
INSERT INTO supply_chain_map (edge_id, map_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
(uuid_generate_v4(), 'bf300000-0000-4000-8000-000000000001', 'bf200000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000000', '71000004-0000-4000-8000-000000000004', 'bf000000-0000-4000-8000-000000000002', 1, 'supplychain_declared', 'ERP', 'unverified', '2026-07-06', '2027-07-06'),
(uuid_generate_v4(), 'bf300000-0000-4000-8000-000000000001', 'bf200000-0000-4000-8000-000000000001', '71000004-0000-4000-8000-000000000004', '71000003-0000-4000-8000-000000000003', 'bf000000-0000-4000-8000-000000000003', 2, 'supplychain_declared', 'SUPPLIER_DECLARED', 'unverified', '2026-07-06', '2027-07-06'),
(uuid_generate_v4(), 'bf300000-0000-4000-8000-000000000001', 'bf200000-0000-4000-8000-000000000001', '71000003-0000-4000-8000-000000000003', '7100000a-0000-4000-8000-00000000000a', 'bf000000-0000-4000-8000-000000000004', 3, 'supplychain_declared', 'SUPPLIER_DECLARED', 'unverified', '2026-07-06', '2027-07-06'),
(uuid_generate_v4(), 'bf300000-0000-4000-8000-000000000001', 'bf200000-0000-4000-8000-000000000001', '7100000a-0000-4000-8000-00000000000a', '71000008-0000-4000-8000-000000000008', 'bf000000-0000-4000-8000-000000000005', 4, 'supplychain_declared', 'SUPPLIER_DECLARED', 'unverified', '2026-07-06', '2027-07-06'),
(uuid_generate_v4(), 'bf300000-0000-4000-8000-000000000001', 'bf200000-0000-4000-8000-000000000001', '71000008-0000-4000-8000-000000000008', '71000006-0000-4000-8000-000000000006', 'bf000000-0000-4000-8000-000000000006', 5, 'supplychain_declared', 'SUPPLIER_DECLARED', 'unverified', '2026-07-06', '2027-07-06');


-- ============================================================
-- 31. PM테스트협력사01~10 — MES 연동 기본정보 채우기
-- ============================================================
-- 문제: "1차협력사 정보는 MES에서 연동" 되는 기본 데이터(회사명/사업자등록번호/
--   주소/담당자 연락처)까지 전부 비워서 만들었었다. 이 기본정보는 원래 MES에서
--   이미 넘어와 있어야 하는 값이라 채워두고, 소재/공장/규제/문서(협력사가 직접
--   입력해야 하는 부분)만 비워둔 채로 유지한다.

UPDATE suppliers SET business_reg_no = '111-86-71001', country = 'KR', address = '경기도 화성시 동탄산단로 101' WHERE supplier_id = '71000001-0000-4000-8000-000000000001';
UPDATE suppliers SET business_reg_no = '111-86-71002', country = 'KR', address = '경기도 화성시 동탄산단로 102' WHERE supplier_id = '71000002-0000-4000-8000-000000000002';
UPDATE suppliers SET business_reg_no = '111-86-71003', country = 'KR', address = '충청남도 아산시 배방읍 산단로 103' WHERE supplier_id = '71000003-0000-4000-8000-000000000003';
UPDATE suppliers SET business_reg_no = '111-86-71004', country = 'KR', address = '충청남도 아산시 배방읍 산단로 104' WHERE supplier_id = '71000004-0000-4000-8000-000000000004';
UPDATE suppliers SET business_reg_no = '111-86-71005', country = 'AU', address = 'Pilbara Mining District, Western Australia' WHERE supplier_id = '71000005-0000-4000-8000-000000000005';
UPDATE suppliers SET business_reg_no = '111-86-71006', country = 'ID', address = 'Sulawesi Tengah Mining Zone, Indonesia' WHERE supplier_id = '71000006-0000-4000-8000-000000000006';
UPDATE suppliers SET business_reg_no = '111-86-71007', country = 'KR', address = '울산광역시 남구 산업로 107' WHERE supplier_id = '71000007-0000-4000-8000-000000000007';
UPDATE suppliers SET business_reg_no = '111-86-71008', country = 'KR', address = '경상북도 포항시 남구 산단로 108' WHERE supplier_id = '71000008-0000-4000-8000-000000000008';
UPDATE suppliers SET business_reg_no = '111-86-71009', country = 'KR', address = '서울특별시 강남구 테헤란로 109' WHERE supplier_id = '71000009-0000-4000-8000-000000000009';
UPDATE suppliers SET business_reg_no = '111-86-71010', country = 'SG', address = '10 Marina Boulevard, Singapore' WHERE supplier_id = '7100000a-0000-4000-8000-00000000000a';

-- 대표 PIC 1명씩(MES 연동 담당자 정보) — factory_id는 아직 공장 미등록이라 NULL.
INSERT INTO supplier_contacts (supplier_id, name, name_en, role, department, email, phone, is_primary, language) VALUES
('71000001-0000-4000-8000-000000000001', '김민준', 'Kim MJ', 'ESG 담당자', 'ESG팀',   'mj.kim@pmtest01.demo',   '+82-31-711-0001', TRUE, 'ko'),
('71000002-0000-4000-8000-000000000002', '이서연', 'Lee SY', 'ESG 담당자', 'ESG팀',   'sy.lee@pmtest02.demo',   '+82-31-711-0002', TRUE, 'ko'),
('71000003-0000-4000-8000-000000000003', '박도윤', 'Park DY', 'ESG 담당자', 'ESG팀',  'dy.park@pmtest03.demo',  '+82-41-711-0003', TRUE, 'ko'),
('71000004-0000-4000-8000-000000000004', '최지우', 'Choi JW', 'ESG 담당자', 'ESG팀',  'jw.choi@pmtest04.demo',  '+82-41-711-0004', TRUE, 'ko'),
('71000005-0000-4000-8000-000000000005', 'James Carter', 'James Carter', 'Compliance Manager', 'Operations', 'j.carter@pmtest05.demo', '+61-8-711-0005', TRUE, 'en'),
('71000006-0000-4000-8000-000000000006', 'Budi Santoso', 'Budi Santoso', 'Mine Manager', 'Operations', 'budi@pmtest06.demo', '+62-21-711-0006', TRUE, 'en'),
('71000007-0000-4000-8000-000000000007', '정하은', 'Jung HE', 'ESG 담당자', 'ESG팀',  'he.jung@pmtest07.demo',  '+82-52-711-0007', TRUE, 'ko'),
('71000008-0000-4000-8000-000000000008', '한지호', 'Han JH', 'ESG 담당자', 'ESG팀',  'jh.han@pmtest08.demo',   '+82-54-711-0008', TRUE, 'ko'),
('71000009-0000-4000-8000-000000000009', '오세훈', 'Oh SH', '구매 담당자', '구매팀',  'sh.oh@pmtest09.demo',    '+82-2-711-0009',  TRUE, 'ko'),
('7100000a-0000-4000-8000-00000000000a', 'Grace Lim', 'Grace Lim', 'Trading Manager', 'Trading', 'grace.lim@pmtest10.demo', '+65-711-0010', TRUE, 'en')
ON CONFLICT DO NOTHING;


-- ============================================================
-- 32. 데모 시현용 — iX3 복제 제품 + 1차(한양셀 변형) 1곳만
-- ============================================================
-- 목적: PM 데모에서 "1차 협력사 1곳(환경성적서·사업자등록증 보유)"만 있는 단순 공급망을
--   보여주기 위한 전용 데이터셋. 실 iX3(d1111111)는 안 건드리고 복제 제품을 새로 만든다.
--   실 데이터와 유사하되 이름만 살짝 변형(한양셀 제조(주) → 한양배터리셀(주)).
--   구성은 최소한 — 회사명 + 서류(사업자등록증/환경성적서 URL)만. 공장/담당자/탄소선언 생략.

-- 32-1. 1차 협력사(한양셀 변형) — 환경성적서 + 사업자등록증 DB 보유(핵심 요건).
INSERT INTO suppliers (supplier_id, tenant_id, company_name, company_name_en, company_name_ko, ceo_name, business_reg_no, provider_type, core_minerals, country, address, business_reg_doc_url, business_reg_doc_name, environmental_report_url, completeness_score, status, risk_level) VALUES
('a5111111-1111-4000-8000-000000000001', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '한양배터리셀(주)', 'Hanyang Battery Cell', '한양배터리셀(주)', 'Kim CEO', '119-86-51001', 'manufacturer', '{"Li":7.1,"Ni":80.0,"Co":10.0,"Mn":10.0}'::jsonb, 'KR', '경상북도 포항시 남구 포항산단로 51', 's3://kira-docs/suppliers/a5111111/biz_reg.pdf', '한양배터리셀_사업자등록증.pdf', 's3://kira-docs/suppliers/a5111111/env_report.pdf', 90, 'supplier_verified', 'low')
ON CONFLICT (supplier_id) DO NOTHING;

-- 32-2. iX3 복제 제품(실 iX3와 사양 동일, 이름/코드만 데모 표기).
INSERT INTO products (product_id, product_code, product_name, manufacturer_id, tenant_id, customer_id, model_name, amperage_ah, type, source_system, external_id) VALUES
('d5111111-0000-4000-8000-000000000001', 'KE-CYL-NCM811-108-DEMO', 'KIRA PRiMX Cylindrical NCM811 108Ah (데모)', 'a0000000-0000-4000-8000-000000000000', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'c0000000-0000-4000-8000-0000000000b1', 'iX3 데모', 108.00, 'battery_pack', 'MANUAL_DEMO', 'DEMO-PROD-IX3')
ON CONFLICT (product_id) DO NOTHING;

-- 32-3. BOM 버전.
INSERT INTO bom_versions (bom_version_id, product_id, version_number, production_from, production_to, status, source_system, external_id) VALUES
('e5111111-0000-4000-8000-000000000001', 'd5111111-0000-4000-8000-000000000001', '1.0', '2025-01-01', NULL, 'active', 'MANUAL_DEMO', 'DEMO-BOM-IX3')
ON CONFLICT (bom_version_id) DO NOTHING;

-- 32-4. BOM 항목 — 기존 부품 재사용(루트 Pack ...01, 1차 Module ...02).
INSERT INTO bom_items (bom_version_id, part_id, required_quantity, required_quantity_unit, percentage, origin_country, source_system, external_id) VALUES
('e5111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000001', 1,   'ea', 100.00, 'KR', 'MANUAL_DEMO', 'DEMO-BI-IX3-PACK'),
('e5111111-0000-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000002', 100, 'ea', 100.00, 'KR', 'MANUAL_DEMO', 'DEMO-BI-IX3-MOD')
ON CONFLICT DO NOTHING;

-- 32-5. 공급망 맵 헤더(completed — 1차까지 검증 완료 상태로 노출).
INSERT INTO supply_chain_maps (map_id, bom_version_id, product_id, status) VALUES
('55511111-0000-4000-8000-000000000001', 'e5111111-0000-4000-8000-000000000001', 'd5111111-0000-4000-8000-000000000001', 'completed')
ON CONFLICT (bom_version_id) DO NOTHING;

-- 32-6. 맵 엣지 — hop0(원청 KIRA) → hop1(한양배터리셀). 1차만.
INSERT INTO supply_chain_map (edge_id, map_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level, link_status, source_system, verification_status, supply_period_from, supply_period_to) VALUES
('55511111-0000-4000-8000-000000000010', '55511111-0000-4000-8000-000000000001', 'e5111111-0000-4000-8000-000000000001', NULL,                                     'a0000000-0000-4000-8000-000000000000', 'b1111111-0000-4000-8000-000000000001', 0, 'supplychain_confirmed', 'ERP', 'verified', '2025-01-01', '2025-12-31'),
('55511111-0000-4000-8000-000000000011', '55511111-0000-4000-8000-000000000001', 'e5111111-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000000', 'a5111111-1111-4000-8000-000000000001', 'b1111111-0000-4000-8000-000000000002', 1, 'supplychain_confirmed', 'ERP', 'verified', '2025-01-01', '2025-12-31')
ON CONFLICT (edge_id) DO NOTHING;

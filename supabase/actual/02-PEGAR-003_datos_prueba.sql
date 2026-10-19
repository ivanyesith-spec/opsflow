-- OpsFlow · modulo datos-piloto · 003
-- 20 propiedades FICTICIAS (TEST-N01 … TEST-N20) y las funciones del modo prueba.
-- Se puede ejecutar mas de una vez: no duplica nada.

insert into public.propiedades (codigo, nombre, zona, pueblo, direccion, camas_dobles, camas_indiv, sofas_cama, banos, es_prueba) values
  ('TEST-N01', 'TEST · Bay View Studio',        'Norte', 'Mellieħa',      'Triq il-Prova 1, Mellieħa',      1, 0, 0, 1, true),
  ('TEST-N02', 'TEST · Sunset Terrace 2BR',     'Norte', 'Mellieħa',      'Triq il-Prova 2, Mellieħa',      2, 0, 1, 2, true),
  ('TEST-N03', 'TEST · Harbour Loft',           'Norte', 'Mellieħa',      'Triq il-Prova 3, Mellieħa',      1, 1, 0, 1, true),
  ('TEST-N04', 'TEST · Family Penthouse',       'Norte', 'St Paul''s Bay', 'Triq il-Prova 4, St Paul''s Bay', 2, 2, 0, 2, true),
  ('TEST-N05', 'TEST · Seafront 1BR',           'Norte', 'St Paul''s Bay', 'Triq il-Prova 5, St Paul''s Bay', 1, 0, 1, 1, true),
  ('TEST-N06', 'TEST · Garden Maisonette',      'Norte', 'St Paul''s Bay', 'Triq il-Prova 6, St Paul''s Bay', 2, 1, 0, 1, true),
  ('TEST-N07', 'TEST · Promenade Apartment',    'Norte', 'Qawra',         'Triq il-Prova 7, Qawra',         2, 0, 0, 1, true),
  ('TEST-N08', 'TEST · Pool Residence 3BR',     'Norte', 'Qawra',         'Triq il-Prova 8, Qawra',         3, 0, 1, 2, true),
  ('TEST-N09', 'TEST · Compact Studio',         'Norte', 'Qawra',         'Triq il-Prova 9, Qawra',         1, 0, 0, 1, true),
  ('TEST-N10', 'TEST · Corner Flat',            'Norte', 'Qawra',         'Triq il-Prova 10, Qawra',        1, 2, 0, 1, true),
  ('TEST-N11', 'TEST · Square View 2BR',        'Norte', 'Buġibba',       'Triq il-Prova 11, Buġibba',      2, 0, 0, 1, true),
  ('TEST-N12', 'TEST · Rooftop Duplex',         'Norte', 'Buġibba',       'Triq il-Prova 12, Buġibba',      2, 1, 1, 2, true),
  ('TEST-N13', 'TEST · Budget Twin',            'Norte', 'Buġibba',       'Triq il-Prova 13, Buġibba',      0, 2, 0, 1, true),
  ('TEST-N14', 'TEST · Marina Suite',           'Norte', 'Buġibba',       'Triq il-Prova 14, Buġibba',      1, 0, 1, 1, true),
  ('TEST-N15', 'TEST · Ridge House',            'Norte', 'Xemxija',       'Triq il-Prova 15, Xemxija',      3, 1, 0, 2, true),
  ('TEST-N16', 'TEST · Valley Apartment',       'Norte', 'Xemxija',       'Triq il-Prova 16, Xemxija',      2, 0, 0, 1, true),
  ('TEST-N17', 'TEST · Quiet 1BR',              'Norte', 'Xemxija',       'Triq il-Prova 17, Xemxija',      1, 0, 0, 1, true),
  ('TEST-N18', 'TEST · Farmhouse',              'Norte', 'Mġarr',         'Triq il-Prova 18, Mġarr',        3, 2, 0, 3, true),
  ('TEST-N19', 'TEST · Village Flat',           'Norte', 'Mġarr',         'Triq il-Prova 19, Mġarr',        1, 1, 0, 1, true),
  ('TEST-N20', 'TEST · Countryside 2BR',        'Norte', 'Mġarr',         'Triq il-Prova 20, Mġarr',        2, 0, 1, 1, true)
on conflict (codigo) do nothing;

-- Genera entre 8 y 14 checkouts al azar sobre propiedades TEST, un tercio con entrada el mismo dia.
create or replace function public.generar_dia_prueba(p_fecha date)
returns int
language plpgsql security definer set search_path = ''
as $$
declare v_n int;
begin
  if public.mi_nivel() is distinct from 'operacion' then
    raise exception 'Solo Operación puede generar días de prueba.';
  end if;
  v_n := 8 + floor(random() * 7)::int;
  insert into public.checkouts (propiedad_id, fecha, hora_salida, hora_entrada, es_prueba, cargado_por)
  select p.id, p_fecha,
         make_time(9 + floor(random() * 3)::int, (floor(random() * 2) * 30)::int, 0),
         case when random() < 0.34 then make_time(15 + floor(random() * 2)::int, 0, 0) end,
         true, (select auth.uid())
  from (select id from public.propiedades where es_prueba and activa order by random() limit v_n) p
  on conflict (propiedad_id, fecha) do update
    set hora_salida = excluded.hora_salida, hora_entrada = excluded.hora_entrada, cargado_en = now();
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Borra TODO lo marcado como prueba. Nunca toca datos reales.
create or replace function public.borrar_datos_prueba()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_c int; v_p int;
begin
  if public.mi_nivel() is distinct from 'operacion' then
    raise exception 'Solo Operación puede borrar los datos de prueba.';
  end if;
  delete from public.checkouts
   where es_prueba or propiedad_id in (select id from public.propiedades where es_prueba);
  get diagnostics v_c = row_count;
  delete from public.propiedades where es_prueba;
  get diagnostics v_p = row_count;
  return jsonb_build_object('checkouts', v_c, 'propiedades', v_p);
end $$;

revoke execute on function public.generar_dia_prueba(date), public.borrar_datos_prueba() from public, anon;
grant  execute on function public.generar_dia_prueba(date), public.borrar_datos_prueba() to authenticated;

-- OpsFlow · modulo limpieza-guiada · 010
-- QR por apartamento, checklist por tipo de limpieza, 4 fotos de cierre y tiempos por apartamento.
-- Se ejecuta UNA vez: SQL Editor → pegar todo → Run.
-- Regla de la casa: todo UPDATE/DELETE lleva WHERE (Supabase bloquea los que no lo llevan).

-- 1. QR por propiedad ------------------------------------------------------
alter table public.propiedades
  add column if not exists qr_token text unique default replace(gen_random_uuid()::text, '-', '');
update public.propiedades set qr_token = replace(gen_random_uuid()::text, '-', '') where qr_token is null;
alter table public.propiedades alter column qr_token set not null;

-- 2. Checklist ---------------------------------------------------------------
create table if not exists public.checklist_pasos (
  id           int generated always as identity primary key,
  tipo         public.tipo_limpieza not null,
  orden        int not null,
  sala         text not null check (sala in ('kitchen', 'bathroom', 'bedroom', 'living', 'final')),
  texto_en     text not null check (length(texto_en) between 2 and 120),
  texto_es     text not null check (length(texto_es) between 2 and 120),
  obligatorio  boolean not null default true,
  activo       boolean not null default true,
  unique (tipo, orden)
);
alter table public.checklist_pasos enable row level security;
revoke all on public.checklist_pasos from anon;
revoke insert, update, delete, truncate on public.checklist_pasos from authenticated;
drop policy if exists "checklist: lectura" on public.checklist_pasos;
create policy "checklist: lectura" on public.checklist_pasos
  for select to authenticated using ((select public.mi_nivel()) is not null);

-- Progreso de cada limpieza
alter table public.limpiezas
  add column if not exists inicio_qr boolean,                          -- true = empezó escaneando el QR; false = "Can't scan"
  add column if not exists personas  int not null default 1 check (personas between 1 and 4),
  add column if not exists checklist jsonb not null default '{}'::jsonb; -- { "id_paso": "hora en que se marcó" }

-- 3. Fotos de cierre ---------------------------------------------------------
create table if not exists public.fotos_cierre (
  id           uuid primary key default gen_random_uuid(),
  limpieza_id  uuid not null references public.limpiezas(id) on delete cascade,
  sala         text not null check (sala in ('bedroom', 'bathroom', 'kitchen', 'living')),
  ruta         text not null,                 -- carpeta/archivo dentro del bucket fotos-cierre
  subida_en    timestamptz not null default now(),
  subida_por   uuid,
  unique (limpieza_id, sala)
);
alter table public.fotos_cierre enable row level security;
revoke all on public.fotos_cierre from anon;
revoke insert, update, delete, truncate on public.fotos_cierre from authenticated;

-- Bucket privado para las fotos
insert into storage.buckets (id, name, public) values ('fotos-cierre', 'fotos-cierre', false)
on conflict (id) do nothing;

-- ¿Puede quien llama subir esta foto? Solo el cleaner de una limpieza EN CURSO, en la carpeta de esa limpieza.
create or replace function public._puede_subir_foto(p_nombre text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1)
      and l.asignada_a = (select auth.uid()) and l.publicada and l.estado = 'en_curso'
      and public.mi_nivel() is not null)
$$;
create or replace function public._puede_ver_foto(p_nombre text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select public._lider_limpieza() or exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1) and l.asignada_a = (select auth.uid()) and public.mi_nivel() is not null)
$$;
revoke execute on function public._puede_subir_foto(text), public._puede_ver_foto(text) from public, anon;
grant  execute on function public._puede_subir_foto(text), public._puede_ver_foto(text) to authenticated;

-- Las filas de fotos las ven el cleaner de esa limpieza, el lider de limpieza y Operacion (misma regla que el bucket)
drop policy if exists "fotos: lectura" on public.fotos_cierre;
create policy "fotos: lectura" on public.fotos_cierre
  for select to authenticated using (public._puede_ver_foto(limpieza_id::text));

drop policy if exists "fotos-cierre: subir" on storage.objects;
drop policy if exists "fotos-cierre: repetir" on storage.objects;
drop policy if exists "fotos-cierre: ver" on storage.objects;
create policy "fotos-cierre: subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'fotos-cierre' and public._puede_subir_foto(name));
create policy "fotos-cierre: repetir" on storage.objects for update to authenticated
  using (bucket_id = 'fotos-cierre' and public._puede_subir_foto(name))
  with check (bucket_id = 'fotos-cierre' and public._puede_subir_foto(name));
create policy "fotos-cierre: ver" on storage.objects for select to authenticated
  using (bucket_id = 'fotos-cierre' and public._puede_ver_foto(name));

-- 4. Funciones del cleaner ------------------------------------------------------
-- Empezar escaneando el QR del apartamento
create or replace function public.iniciar_con_qr(p_id uuid, p_qr text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_token text; v_cod text;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'asignada' then raise exception 'Solo se puede empezar una limpieza asignada.'; end if;
  select qr_token, codigo into v_token, v_cod from public.propiedades where id = v.propiedad_id;
  -- El QR lleva "OPSFLOW:<token>"; se acepta tambien el token solo
  if coalesce(regexp_replace(btrim(p_qr), '^OPSFLOW:', ''), '') <> v_token then
    raise exception 'This QR is not for %.', v_cod;
  end if;
  update public.limpiezas set estado = 'en_curso', inicio = now(), inicio_qr = true where id = p_id;
  perform public._evento('limpieza iniciada (QR)', p_id, null);
end $$;

-- "Can't scan": empezar sin QR (queda marcado para el lider)
create or replace function public.iniciar_limpieza(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'asignada' then raise exception 'Solo se puede empezar una limpieza asignada.'; end if;
  update public.limpiezas set estado = 'en_curso', inicio = now(), inicio_qr = false where id = p_id;
  perform public._evento('limpieza iniciada (sin QR)', p_id, null);
end $$;

-- Marcar o desmarcar un paso de la checklist
create or replace function public.marcar_paso(p_id uuid, p_paso int, p_hecho boolean)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if not exists (select 1 from public.checklist_pasos where id = p_paso and tipo = v.tipo and activo) then
    raise exception 'Ese paso no es de esta limpieza.';
  end if;
  update public.limpiezas
     set checklist = case when p_hecho then checklist || jsonb_build_object(p_paso::text, now())
                          else checklist - p_paso::text end
   where id = p_id;
end $$;

-- Cuantas personas limpian (para que el tiempo medio sea justo)
create or replace function public.marcar_personas(p_id uuid, p_n int)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado not in ('asignada', 'en_curso') then raise exception 'Esta limpieza ya está cerrada.'; end if;
  if p_n not between 1 and 4 then raise exception 'Entre 1 y 4 personas.'; end if;
  update public.limpiezas set personas = p_n where id = p_id;
end $$;

-- Apuntar una foto ya subida al bucket
create or replace function public.registrar_foto(p_id uuid, p_sala text, p_ruta text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if p_sala not in ('bedroom', 'bathroom', 'kitchen', 'living') then raise exception 'Sala no válida.'; end if;
  if split_part(p_ruta, '/', 1) <> p_id::text then raise exception 'La foto no es de esta limpieza.'; end if;
  insert into public.fotos_cierre (limpieza_id, sala, ruta, subida_por)
  values (p_id, p_sala, p_ruta, (select auth.uid()))
  on conflict (limpieza_id, sala) do update set ruta = excluded.ruta, subida_en = now(), subida_por = excluded.subida_por;
end $$;

-- Terminar: ahora exige los pasos obligatorios y las 4 fotos
create or replace function public.terminar_limpieza(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_faltan int; v_fotos int;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  select count(*) into v_faltan from public.checklist_pasos p
   where p.tipo = v.tipo and p.activo and p.obligatorio and not (v.checklist ? p.id::text);
  if v_faltan > 0 then raise exception 'Checklist not finished: % step(s) left.', v_faltan; end if;
  select count(distinct sala) into v_fotos from public.fotos_cierre where limpieza_id = p_id;
  if v_fotos < 4 then raise exception 'Take the 4 photos first (% of 4).', v_fotos; end if;
  update public.limpiezas set estado = 'terminada', fin = now() where id = p_id;
  perform public._evento('limpieza terminada', p_id, null);
end $$;

-- La checklist de una limpieza, con lo hecho y las fotos (cleaner de esa limpieza, lider o Operacion)
create or replace function public.mi_checklist(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  select * into v from public.limpiezas where id = p_id;
  if not found or public.mi_nivel() is null
     or not (public._lider_limpieza() or (v.asignada_a = (select auth.uid()) and v.publicada)) then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  return jsonb_build_object(
    'inicio_qr', v.inicio_qr, 'personas', v.personas, 'estado', v.estado,
    'pasos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'sala', p.sala, 'en', p.texto_en, 'es', p.texto_es,
                          'obligatorio', p.obligatorio, 'hecho', v.checklist ? p.id::text) order by p.orden)
                       from public.checklist_pasos p where p.tipo = v.tipo and p.activo), '[]'::jsonb),
    'fotos', coalesce((select jsonb_object_agg(f.sala, f.ruta) from public.fotos_cierre f where f.limpieza_id = p_id), '{}'::jsonb));
end $$;

-- 5. Tiempos ------------------------------------------------------------------
-- Por apartamento y tipo (lider de limpieza y Operacion). Solo limpiezas con QR, entre 10 min y 6 h.
create or replace function public.tiempos_aptos(p_dias int default 90)
returns table (codigo text, nombre text, tipo text, limpiezas bigint, media_min int, mediana_min int, ultima date)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación.'; end if;
  return query
  select p.codigo, p.nombre, l.tipo::text, count(*),
         round(avg(extract(epoch from (l.fin - l.inicio)) / 60))::int,
         round(percentile_cont(0.5) within group (order by extract(epoch from (l.fin - l.inicio)) / 60))::int,
         max(l.fecha)
  from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
  where l.estado = 'terminada' and l.inicio_qr and l.fin is not null and l.inicio is not null
    and l.fecha >= current_date - p_dias
    and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'
  group by p.codigo, p.nombre, l.tipo
  order by p.codigo, l.tipo::text;
end $$;

-- Por persona (solo Operacion)
create or replace function public.tiempos_personas(p_dias int default 90)
returns table (cleaner text, tipo text, limpiezas bigint, media_min int, sin_qr bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
  return query
  select pf.nombre, l.tipo::text,
         count(*) filter (where l.inicio_qr and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'),
         round(avg(extract(epoch from (l.fin - l.inicio)) / 60)
               filter (where l.inicio_qr and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'))::int,
         count(*) filter (where l.inicio_qr is false)
  from public.limpiezas l join public.perfiles pf on pf.id = l.asignada_a
  where l.estado = 'terminada' and l.fecha >= current_date - p_dias
  group by pf.nombre, l.tipo
  order by pf.nombre, l.tipo::text;
end $$;

-- 6. QR para imprimir (solo Operacion) -----------------------------------------
create or replace function public.qr_lista()
returns table (codigo text, nombre text, pueblo text, qr text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
  return query select p.codigo, p.nombre, p.pueblo, 'OPSFLOW:' || p.qr_token
               from public.propiedades p where p.activa order by p.codigo;
end $$;

create or replace function public.regenerar_qr(p_propiedad uuid)
returns text language plpgsql security definer set search_path = ''
as $$
declare v text := replace(gen_random_uuid()::text, '-', '');
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
  update public.propiedades set qr_token = v where id = p_propiedad;
  if not found then raise exception 'Esa propiedad no existe.'; end if;
  return 'OPSFLOW:' || v;
end $$;

-- 7. Fotos de mas de 30 dias (las usa la tarea de borrado; solo el servidor) ----------
create or replace function public.fotos_caducadas(p_dias int default 30)
returns table (ruta text)
language sql security definer set search_path = ''
as $$
  with b as (delete from public.fotos_cierre where subida_en < now() - make_interval(days => p_dias) returning fotos_cierre.ruta)
  select b.ruta from b
$$;

-- Permisos de ejecucion
revoke execute on function public.iniciar_con_qr(uuid, text), public.marcar_paso(uuid, int, boolean),
  public.marcar_personas(uuid, int), public.registrar_foto(uuid, text, text), public.mi_checklist(uuid),
  public.tiempos_aptos(int), public.tiempos_personas(int), public.qr_lista(), public.regenerar_qr(uuid)
  from public, anon;
grant execute on function public.iniciar_con_qr(uuid, text), public.marcar_paso(uuid, int, boolean),
  public.marcar_personas(uuid, int), public.registrar_foto(uuid, text, text), public.mi_checklist(uuid),
  public.tiempos_aptos(int), public.tiempos_personas(int), public.qr_lista(), public.regenerar_qr(uuid)
  to authenticated;
revoke execute on function public.fotos_caducadas(int) from public, anon, authenticated;
grant  execute on function public.fotos_caducadas(int) to service_role;

-- 8. Checklists por tipo (BORRADOR para que housekeeping corrija) -------------------
-- Se cargan solo si la tabla esta vacia, para no pisar cambios.
do $$
begin
  if exists (select 1 from public.checklist_pasos) then return; end if;

  -- NORMAL (checkout)
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio) values
  ('normal', 10, 'bedroom',  'Open windows and air the apartment',            'Abrir ventanas y ventilar', true),
  ('normal', 20, 'bedroom',  'Strip beds, make beds with clean linens',        'Quitar sábanas y hacer camas con linens limpios', true),
  ('normal', 30, 'bedroom',  'Dust surfaces, check under beds',                'Polvo en superficies, revisar debajo de camas', true),
  ('normal', 40, 'bathroom', 'Clean toilet, sink and shower',                  'Limpiar inodoro, lavabo y ducha', true),
  ('normal', 50, 'bathroom', 'Clean mirror and fittings',                      'Limpiar espejo y grifería', true),
  ('normal', 60, 'bathroom', 'Fresh towels and toilet paper',                  'Toallas limpias y papel higiénico', true),
  ('normal', 70, 'kitchen',  'Wash and put away dishes',                       'Lavar y guardar la vajilla', true),
  ('normal', 80, 'kitchen',  'Empty and wipe fridge',                          'Vaciar y limpiar la nevera', true),
  ('normal', 90, 'kitchen',  'Clean hob, microwave and counters',              'Limpiar placa, microondas y encimeras', true),
  ('normal',100, 'living',   'Dust and tidy living area',                      'Polvo y orden en el salón', true),
  ('normal',110, 'living',   'Vacuum and mop all floors',                      'Aspirar y fregar todos los suelos', true),
  ('normal',120, 'final',    'All trash out, new bags in bins',                'Toda la basura fuera, bolsas nuevas', true),
  ('normal',130, 'final',    'Restock amenities (soap, coffee, etc.)',         'Reponer amenities (jabón, café, etc.)', true),
  ('normal',140, 'final',    'Lights, AC off · windows closed · key back',     'Luces y AC apagados · ventanas cerradas · llave en su sitio', true),
  ('normal',150, 'final',    'Report anything broken or missing',              'Avisar de cualquier rotura o faltante', false);

  -- REFRESH (repaso sin huesped nuevo)
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio) values
  ('refresh', 10, 'bedroom',  'Air the apartment, smooth beds',                'Ventilar y estirar camas', true),
  ('refresh', 20, 'bathroom', 'Quick clean of toilet, sink and shower',        'Repaso de inodoro, lavabo y ducha', true),
  ('refresh', 30, 'kitchen',  'Wipe counters and sink',                        'Repasar encimeras y fregadero', true),
  ('refresh', 40, 'living',   'Dust surfaces and vacuum',                      'Polvo y aspirar', true),
  ('refresh', 50, 'final',    'Check amenities and trash',                     'Revisar amenities y basura', true),
  ('refresh', 60, 'final',    'Lights, AC off · windows closed',               'Luces y AC apagados · ventanas cerradas', true);

  -- DEEP: todo lo de normal + extras
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio)
  select 'deep', orden, sala, texto_en, texto_es, obligatorio from public.checklist_pasos where tipo = 'normal';
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio) values
  ('deep', 35, 'bedroom',  'Inside wardrobes and drawers',                    'Dentro de armarios y cajones', true),
  ('deep', 36, 'bedroom',  'Check mattresses and curtains',                   'Revisar colchones y cortinas', true),
  ('deep', 55, 'bathroom', 'Descale and clean grout',                         'Quitar cal y limpiar juntas', true),
  ('deep', 85, 'kitchen',  'Oven and fridge deep clean',                      'Horno y nevera a fondo', true),
  ('deep', 86, 'kitchen',  'Inside kitchen cupboards',                        'Dentro de los armarios de cocina', true),
  ('deep',105, 'living',   'Windows and glass inside',                        'Cristales y ventanas por dentro', true),
  ('deep',106, 'living',   'Behind and under furniture',                      'Detrás y debajo de los muebles', true);

  -- HUESPED DENTRO
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio) values
  ('huesped_dentro', 10, 'final',    'Greet guest · ask what they need',      'Saludar al huésped · preguntar qué necesita', true),
  ('huesped_dentro', 20, 'bathroom', 'Clean bathroom',                        'Limpiar el baño', true),
  ('huesped_dentro', 30, 'bathroom', 'Fresh towels',                          'Toallas limpias', true),
  ('huesped_dentro', 40, 'final',    'Take trash out',                        'Sacar la basura', true),
  ('huesped_dentro', 50, 'final',    'Do not touch personal items',           'No tocar objetos personales', true);

  -- PARA FOTO: normal + puesta en escena
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio)
  select 'foto', orden, sala, texto_en, texto_es, obligatorio from public.checklist_pasos where tipo = 'normal';
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio) values
  ('foto', 25, 'bedroom', 'Perfect beds, cushions in place',                  'Camas perfectas, cojines colocados', true),
  ('foto',115, 'living',  'No personal objects, staging done',                'Sin objetos personales, puesta en escena', true);

  -- POST MANTENIMIENTO
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio) values
  ('post_mantenimiento', 10, 'living',   'Remove dust and debris from works',  'Quitar polvo y restos de la obra', true),
  ('post_mantenimiento', 20, 'living',   'Clean the repaired area',            'Limpiar la zona reparada', true),
  ('post_mantenimiento', 30, 'bathroom', 'Clean bathroom',                     'Limpiar el baño', true),
  ('post_mantenimiento', 40, 'living',   'Vacuum and mop floors',              'Aspirar y fregar suelos', true),
  ('post_mantenimiento', 50, 'final',    'Check everything works · lights off','Comprobar que todo funciona · luces apagadas', true);
end $$;

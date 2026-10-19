#!/usr/bin/env python3
"""Genera supabase/migraciones/34-PEGAR-permisos_sustituciones.sql
- Partes escritas a mano: plantilla34.sql (marcas @@GENERADO_FUNCIONES@@ y @@GENERADO_POLITICAS@@)
- Partes generadas: la ÚLTIMA definición de cada función/política de 00-MONTAR (= backend 1–33)
  con la comprobación "líder de X" cambiada por _es_lider('X') (líder real o sustituto vigente)."""
import re, sys
D = sys.argv[1]                       # carpeta del repo
S = sys.argv[2]                       # carpeta de este generador
M = open(f'{D}/supabase/pruebas/00-MONTAR-proyecto_pruebas.sql', encoding='utf-8').read()

def ultima_funcion(nombre):
    pos = [m.start() for m in re.finditer(r'create or replace function public\.' + nombre + r'\(', M)]
    assert pos, nombre
    i = pos[-1]
    j = M.index('as $$', i) + 5
    k = M.index('$$;', j) + 3
    return M[i:k]

def ultima_politica(nombre, tabla):
    pat = re.compile(r'create policy "' + re.escape(nombre) + r'"\s+on public\.' + tabla + r'\b.*?\);', re.S)
    ms = list(pat.finditer(M))
    assert ms, nombre
    return ms[-1].group(0)

def arr(lista):   # "'A', 'B'" -> array['A', 'B']
    return 'array[' + lista + ']'

REGLAS = [
    # dentro de políticas (con select)
    (r"\(select public\.mi_nivel\(\)\) = 'lider' and \(select public\.mi_departamento\(\)\) = '(\w+)'",
     lambda m: f"(select public._es_lider('{m.group(1)}'))"),
    (r"\(select public\.mi_nivel\(\)\) = 'lider' and \(select public\.mi_departamento\(\)\) in \(([^)]*)\)",
     lambda m: f"(select public._es_lider_en({arr(m.group(1))}))"),
    (r"\(select public\.mi_departamento\(\)\) in \(([^)]*)\) and \(select public\.mi_nivel\(\)\) = 'lider'",
     lambda m: f"(select public._es_lider_en({arr(m.group(1))}))"),
    (r"\(\(select public\.mi_nivel\(\)\) = 'lider' and departamento = \(select public\.mi_departamento\(\)\)\)",
     lambda m: "public._es_lider(departamento)"),
    (r"using \(\(select public\.mi_nivel\(\)\) in \('lider', 'operacion'\)\)",
     lambda m: "using ((select public.mi_nivel()) in ('lider', 'operacion') or (select public._soy_sustituto()))"),
    # dentro de funciones
    (r"public\.mi_nivel\(\) = 'lider' and public\.mi_departamento\(\) = '(\w+)'",
     lambda m: f"public._es_lider('{m.group(1)}')"),
    (r"public\.mi_nivel\(\) = 'lider' and public\.mi_departamento\(\) in \(([^)]*)\)",
     lambda m: f"public._es_lider_en({arr(m.group(1))})"),
    (r"public\.mi_nivel\(\) = 'lider' and public\.mi_departamento\(\) = (case when [^\n]*? end)\)",
     lambda m: f"public._es_lider({m.group(1)}))"),
    (r"v_nivel = 'lider' and v_dep = 'Limpieza'", lambda m: "public._es_lider('Limpieza')"),
    (r"public\.mi_nivel\(\) = 'lider' or l\.zona = public\.mi_zona\(\)",
     lambda m: "public._es_lider('Drivers') or l.zona = public.mi_zona()"),
    # destinatarios de avisos: líder real o sustituto vigente (el sustituto, sin filtro de zona)
    (r"p\.nivel = 'lider' and p\.departamento = '(\w+)'\n(\s*)and \(p\.zona is null or p\.zona = (\w+)\.zona\)",
     lambda m: f"public._es_lider_id(p.id, '{m.group(1)}')\n{m.group(2)}and (p.zona is null or p.zona = {m.group(3)}.zona or p.nivel = 'operador')"),
    (r"\(p\.nivel = 'lider' and \(p\.zona is null or p\.zona = pe\.zona\)\)",
     lambda m: "(public._es_lider_id(p.id, 'Drivers') and (p.zona is null or p.zona = pe.zona or p.nivel = 'operador'))"),
    (r"p\.nivel = 'lider' and p\.departamento in \('Limpieza', 'Drivers'\) and \(p\.zona is null or p\.zona = li\.zona\)",
     lambda m: "(public._es_lider_id(p.id, 'Limpieza') or public._es_lider_id(p.id, 'Drivers')) and (p.zona is null or p.zona = li.zona or p.nivel = 'operador')"),
    (r"case when p\.nivel = 'lider' and p\.departamento = 'Limpieza' then",
     lambda m: "case when public._es_lider_id(p.id, 'Limpieza') then"),
]

def transformar(txt, nombre):
    for pat, rep in REGLAS:
        txt = re.sub(pat, rep, txt)
    resto = [l.strip() for l in txt.split('\n') if "'lider'" in l]
    resto = [l for l in resto if "in ('lider', 'operacion') or (select public._soy_sustituto())" not in l]
    assert not resto, (nombre, resto)
    return txt

FUNCIONES = ['_puede_ver_foto', 'bolsas_dia', 'bolsas_etiquetas', 'cargar_checkouts', 'entradas_dia', 'horario_dia',
             'marcar_entregado', 'no_pude_entregar', 'marcar_preparado', 'preparar_bolsa', 'resolver_incidencia',
             'rutas_hoy', 'avisos_para']
POLITICAS = [('perfiles: lectura por nivel', 'perfiles'), ('propiedades: leen lideres y operacion', 'propiedades'),
             ('checkouts: leen lideres y operacion', 'checkouts'), ('limpiezas: lectura por rol', 'limpiezas'),
             ('pendientes: lectura por rol', 'pendientes'), ('bolsas: lectura', 'bolsas'),
             ('entradas: lectura', 'entradas_equipo'), ('rutas: lectura', 'rutas_driver'),
             ('equipos: lectura', 'equipos'), ('equipo_miembros: lectura', 'equipo_miembros')]

fn = []
for n in FUNCIONES:
    orig = ultima_funcion(n)
    nuevo = transformar(orig, n)
    assert nuevo != orig, n
    fn.append(f'-- {n}: igual que en el backend actual; solo cambia "líder de X" por _es_lider(\'X\')\n{nuevo}\n')
po = []
for n, t in POLITICAS:
    orig = ultima_politica(n, t)
    nuevo = transformar(orig, n)
    assert nuevo != orig, n
    po.append(f'drop policy if exists "{n}" on public.{t};\n{nuevo}\n')

P = open(f'{S}/plantilla34.sql', encoding='utf-8').read()
# Funciones de asignar (mismo cuerpo que en la 34 anterior): códigos de error 42501 (sin permiso) y 22023 (dato no válido)
A = open(f'{S}/asignar_actual.sql', encoding='utf-8').read()
def codigo(m):
    linea = m.group(0)
    cod = '42501' if '_asigna(' in linea else '22023'
    return re.sub(r"raise exception '([^']*)';", lambda r: f"raise exception using errcode = '{cod}', message = '{r.group(1)}';", linea)
A = re.sub(r"[^\n]*raise exception '[^']*';[^\n]*", codigo, A)
assert "raise exception '" not in A
P = P.replace('@@ASIGNAR@@', A.rstrip() + '\n')
out = P.replace('@@GENERADO_FUNCIONES@@', '\n'.join(fn)).replace('@@GENERADO_POLITICAS@@', '\n'.join(po))
assert '@@' not in out
open(f'{D}/supabase/migraciones/34-PEGAR-permisos_sustituciones.sql', 'w', encoding='utf-8', newline='\n').write(out)
print('34 generada:', len(FUNCIONES), 'funciones,', len(POLITICAS), 'politicas,', out.count('\n'), 'lineas')

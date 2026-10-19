// OpsFlow · pruebas locales (sin red ni Supabase) de la etapa 1: asignación solo por el líder + sustituciones.
// Ejecutar desde la raíz del repo:  node tests/permisos.test.cjs
// NO sustituyen a supabase/migraciones/35-PEGAR-pruebas_permisos.sql ni a las E2E.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const raiz = path.join(__dirname, '..');
const leer = (...p) => fs.readFileSync(path.join(raiz, ...p), 'utf8').replace(/\r\n/g, '\n');
const html = leer('index.html');
const sql = leer('supabase', 'migraciones', '34-PEGAR-permisos_sustituciones.sql');
const sql35 = leer('supabase', 'migraciones', '35-PEGAR-pruebas_permisos.sql');
const montar = leer('supabase', 'pruebas', '00-MONTAR-proyecto_pruebas.sql');
let n = 0;
const prueba = (nombre, f) => { f(); n++; console.log('OK  ' + nombre); };

// 1. Los scripts de index.html siguen siendo JavaScript válido
prueba('index.html: todos los <script> en línea compilan', () => {
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  assert.ok(scripts.length > 0);
  scripts.forEach((s, i) => new vm.Script(s, { filename: `index.html#script${i}` }));
});

// 2. Pestañas por rol (se ejecuta el tabsDe real de index.html)
const fuente = html.match(/const asignaDe = [^\n]+\n/)[0] + html.match(/function tabsDe\(\)\{[\s\S]*?\n\}\n/)[0];
const tabs = perfil => {
  const ctx = { perfil };
  vm.runInNewContext(fuente + 'resultado = tabsDe().map(t => t[0]);', ctx);
  return ctx.resultado;
};
prueba('Operación: Seguimiento y Sustituciones, pero NO Asignar', () => {
  const t = tabs({ nivel: 'operacion', departamento: 'Operación' });
  assert.ok(!t.includes('asignar'));
  for (const k of ['seguimiento', 'drivers', 'linens', 'tablero', 'sustituciones']) assert.ok(t.includes(k), k);
});
prueba('Líder de limpieza: Asignar y Seguimiento, sin Sustituciones', () => {
  const t = tabs({ nivel: 'lider', departamento: 'Limpieza' });
  assert.ok(t.includes('asignar') && t.includes('seguimiento'));
  assert.ok(!t.includes('sustituciones'));
});
prueba('Otros líderes no ven Asignar ni Sustituciones', () => {
  for (const dep of ['Drivers', 'Linens', 'Bodega']) {
    const t = tabs({ nivel: 'lider', departamento: dep });
    assert.ok(!t.includes('asignar') && !t.includes('sustituciones'), dep);
  }
});

// 3. Drivers: el selector "Asignar a…" solo para el líder de drivers (o su sustituto)
prueba('Selector de asignar driver condicionado a asignaDe("Drivers")', () => {
  assert.match(html, /asignaDe\('Drivers'\) \? `<select data-asig=/);
  assert.equal((html.match(/data-asig="/g) || []).length, 1, 'no debe haber otro selector data-asig sin condición');
});

// 4. Migración 34
const cuerpo = nombre => {
  const m = sql.match(new RegExp(`create or replace function public\\.${nombre}\\([\\s\\S]*?end \\$\\$;`));
  assert.ok(m, 'falta ' + nombre);
  return m[0];
};
prueba('SQL: las 6 funciones de asignación usan _asigna() y no mencionan operacion', () => {
  const dep = { asignar_limpieza: 'Limpieza', publicar_orden: 'Limpieza', guardar_equipo: 'Limpieza',
                deshacer_equipo: 'Limpieza', fijar_entrada: 'Limpieza', asignar_tarea: 'Drivers' };
  for (const [f, d] of Object.entries(dep)) {
    const c = cuerpo(f);
    assert.ok(c.includes(`public._asigna('${d}')`), f);
    assert.ok(!/operacion|_lider_limpieza/.test(c), f + ' todavía deja pasar a Operación');
  }
});
prueba('SQL: _asigna no incluye Operación y no se puede llamar desde la app', () => {
  assert.match(sql, /_asigna\(p_dep text\)[\s\S]*?as \$\$ select public\._es_lider\(p_dep\) \$\$;/);
  assert.match(sql, /revoke execute on function public\._asigna\(text\) from public, anon, authenticated;/);
});
prueba('SQL: sustituto solo de su propio departamento y solo dentro de las fechas; su nivel no cambia', () => {
  const c = sql.match(/create or replace function public\._es_lider_id\([\s\S]*?\$\$;/)[0];
  for (const x of ['p.departamento = p_dep', "p.nivel = 'operador'", 's.departamento = p_dep', 's.revocada_en is null', 'now() >= s.desde', 'now() < s.hasta'])
    assert.ok(c.includes(x), x);
  const nv = sql.match(/create or replace function public\.mi_nivel\(\)[\s\S]*?\$\$;/)[0];
  assert.ok(!/sustituc/.test(nv), 'mi_nivel() no debe mirar sustituciones: el sustituto sigue siendo operador');
  assert.ok(!/data\.nivel = 'lider'/.test(html), 'la app no debe convertir al sustituto en líder al cargar el perfil');
});
prueba('SQL: soltar_tarea sin Operación; la tarea asignada por el líder solo la suelta el líder', () => {
  const c = cuerpo('soltar_tarea');
  assert.ok(!/operacion/.test(c));
  assert.ok(c.includes("_es_lider('Drivers')") && c.includes('v.asignado_por is not null'));
  assert.match(html, /\$\{t\.asignado \? '' : `<button class="btn ghost" data-soltar=/);
});
prueba('SQL: ninguna regla de líder queda sin el sustituto (no queda "lider" suelto en lo generado)', () => {
  const generado = sql.slice(sql.indexOf('-- 5. Funciones y reglas'), sql.indexOf('-- 6. Nombrar'));
  assert.ok(generado.length > 1000);
  const sueltos = generado.split('\n').filter(l => /'lider'/.test(l) && !l.includes("in ('lider', 'operacion') or (select public._soy_sustituto())"));
  assert.deepEqual(sueltos, []);
});
prueba('SQL: denegaciones con código 42501 y solapes imposibles en la tabla', () => {
  const permisos = [...sql.matchAll(/raise exception using errcode = '(\w+)', message = (?:format\()?'(Solo [^']*)'/g)];
  assert.ok(permisos.length >= 10);
  // "Solo se puede asignar a un cleaner activo" y parecidos son datos no válidos (22023), no permisos
  for (const [, cod, msg] of permisos) assert.equal(cod, /^Solo (se puede|se asigna|cleaners)/.test(msg) ? '22023' : '42501', msg);
  assert.match(sql, /exclude using gist \(departamento with =, tstzrange\(desde, hasta\) with &&\) where \(revocada_en is null\)/);
  assert.match(sql, /pg_advisory_xact_lock\(hashtext\('opsflow\.sustituciones\.' \|\| p_departamento\)\)/);
});
prueba('SQL: nombrar/revocar solo Operación; tabla cerrada al navegador', () => {
  assert.ok(cuerpo('nombrar_sustituto').includes("mi_nivel() is distinct from 'operacion'"));
  assert.ok(cuerpo('revocar_sustitucion').includes("mi_nivel() is distinct from 'operacion'"));
  assert.match(sql, /revoke all on public\.sustituciones from anon, authenticated;/);
});

// 5. Entorno y prueba 35
prueba('Entorno: 00-MONTAR deja la marca; 34 y 35 la exigen y rechazan producción', () => {
  assert.match(montar, /insert into public\.opsflow_entorno \(id, tipo, proyecto\) values \(1, 'pruebas', current_setting\('opsflow\.proyecto'\)\)/);
  for (const [nombre, t] of [['00', montar], ['34', sql], ['35', sql35]]) {
    assert.ok(t.includes("select set_config('opsflow.proyecto', 'ESCRIBE-AQUI-EL-ID-DEL-PROYECTO', false);"), nombre);
    assert.ok(t.includes("'zxsiantglodsqqvigndk'"), nombre + ' no rechaza producción');
  }
  for (const t of [sql, sql35]) assert.ok(t.includes("v_tipo is distinct from 'pruebas'") && t.includes('v_proy <> v'));
});
prueba('35: no borra nada; todo se deshace solo y comprueba códigos de error', () => {
  assert.ok(!/^\s*delete from/im.test(sql35), 'la prueba no debe borrar datos');
  assert.ok(sql35.includes("raise exception 'FIN_DE_LAS_PRUEBAS'"));
  assert.ok(!sql35.includes('pg_temp.falla('), 'ya no se acepta "cualquier error"');
  assert.ok((sql35.match(/pg_temp\.deniega\(/g) || []).length >= 20);
});

// 6. Idiomas: los textos nuevos tienen traducción en el diccionario EN/ES
prueba('I18N: textos de sustituciones y mensajes del servidor traducidos', () => {
  const dic = html.match(/const I18N_DIC = `([\s\S]*?)`;/)[1];
  const claves = new Set(dic.split('\n').filter(l => l.includes(' | ')).map(l => l.slice(0, l.indexOf(' | ')).trim()));
  const mensajes = [...sql.matchAll(/message = (?:format\()?'([^']+)'/g)].map(m => m[1])
    .filter(m => /sustitu|Solo el líder|Solo el driver|Solo Operación|la asignó el líder|Departamento no válido/.test(m));
  assert.ok(mensajes.length >= 10);
  for (const k of ['Sustituciones', 'Nombrar sustituto', 'Revocar', 'Vigente', 'Programada', 'Revocada', 'Sin driver', 'Vista de líder', 'Mi trabajo', ...mensajes]) {
    const clave = k.replace(/\d+/g, '#').replace(/%s/g, '{0}');
    assert.ok(claves.has(clave), 'sin traducción: ' + clave);
  }
});

console.log(`\n${n} pruebas OK`);

# TU COMUNIDAD — FULL BUILD PROGRAM

Fecha de inicio: 2026-09-18
Rama aislada: `tc/full-build-20260918`
Base: `debelop`
Entorno backend permitido: `tu-comunidad-staging`
Producción / merge / deploy: NO autorizado por este programa.

## Objetivo
Construir TU COMUNIDAD por bloques amplios hasta cubrir el sistema completo conocido, sin detener el avance por errores cosméticos o no bloqueantes.

## Regla de errores
### CORREGIR DE INMEDIATO — bloquea avance
- vulnerabilidad de seguridad;
- exposición indebida de datos privados;
- pérdida/corrupción de datos;
- RLS o autorización incorrecta;
- ledger/pagos inconsistentes;
- custodia/trazabilidad inválida;
- migración o contrato que rompe la fuente de verdad;
- contradicción con una regla canónica;
- error que impide compilar, ejecutar o continuar el flujo que se está construyendo.

### REGISTRAR Y DIFERIR — no bloquea avance
- defectos visuales;
- copy/texto imperfecto;
- warnings no funcionales;
- optimizaciones de rendimiento no urgentes;
- índices sin uso sin evidencia de daño;
- UX secundaria;
- limpieza/refactor no necesaria para el bloque actual.

### ELIMINAR SOLO CON EVIDENCIA
- código muerto;
- Actions sin uso;
- demos obsoletas;
- duplicados;
- componentes sin dependencias.
Nunca borrar solo para reducir Issues.

## Orden de construcción
0. Reconciliar fuente de verdad: staging, migraciones, contratos, rama de trabajo.
1. Identidad, perfiles, roles, privacidad y territorio.
2. Organizaciones, tiendas, catálogo territorial, disponibilidad y carrito/checkout.
3. Pedidos, subpedidos, paquetes, contenedores y tracking.
4. Viaje real del conductor intercomunitario, capacidad, oportunidades de carga y rutas.
5. PTC, custodia append-only, evidencia, devoluciones y última milla.
6. Afiliaciones, requisitos, aprobaciones y activación de capacidades.
7. Pagos/ledger, splits, retenciones, reembolsos, liquidaciones, MTC/TCX y vouchers.
8. Notificaciones, incidentes, soporte, reclamos y administración.
9. Mapas, ubicaciones, SAFE/HANDOFF/PTC_PICKUP y experiencia territorial.
10. Idiomas es/en/chj/kjb, procedencia y validación humana.
11. SABERES, menores, tutor/guardian, cursos, progreso, seguridad y avatar.
12. Productores/agricultura/cardamomo, lotes, custodia, transporte, compradores y ofertas.
13. Offline/sync/conflictos, observabilidad, auditoría, métricas y recuperación.
14. QA por rol, limpieza final, deuda técnica y eliminación de lo innecesario.

## Autonomía del equipo
### TC Coordinador
Puede priorizar, dividir, reasignar y continuar trabajo mientras no cruce un bloqueo rojo.

### TC Desarrollo
Puede implementar cambios de alcance verde/amarillo en esta rama y staging. No puede tocar Production ni redefinir reglas canónicas.

### TC Guardian
Audita continuamente. Los fallos no bloqueantes van al backlog; los críticos bloquean el bloque afectado.

### QA por rol
Prueba el flujo construido. Un fallo cosmético se registra; un fallo que cambia datos, permisos, privacidad, dinero o custodia bloquea.

### Lucas
Se escala solo cuando haya:
- cambio de visión/regla canónica;
- cambio económico material;
- nueva categoría de dato privado;
- cambio legal;
- producción/merge/deploy;
- decisión irreversible o destructiva;
- contradicción que el equipo no pueda resolver con evidencia.

## Ciclo
BUILD -> AUDIT -> QA -> 
- PASS: continuar siguiente bloque
- FAIL NO BLOQUEANTE: registrar y continuar
- FAIL CRÍTICO: reparar y repetir
- DECISIÓN L3/L4: escalar a Lucas

## Definition of Done del programa
El programa no termina por llegar a 0 Issues. Termina cuando:
- los flujos principales están conectados de punta a punta;
- staging y código representan la misma arquitectura;
- no existen fallos críticos conocidos;
- el backlog diferido está clasificado;
- Guardian y QA han verificado los flujos principales;
- Production sigue intacto hasta autorización explícita de Lucas.

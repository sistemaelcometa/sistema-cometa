# Arquitectura Supabase - El Cometa

Este documento define el contrato inicial de datos para migrar el sistema a Supabase/PostgreSQL sin convertir el frontend en fuente de verdad.

## Principios

- Supabase/PostgreSQL es la unica fuente de verdad.
- El frontend envia intenciones y datos de entrada, no estados finales criticos.
- Los saldos, estados derivados, totales, margenes y reportes se calculan desde datos confirmados.
- Las escrituras criticas deben pasar por RPCs transaccionales.
- Las lecturas deben filtrar, ordenar y paginar en PostgreSQL.
- El cache futuro es descartable y nunca reemplaza a la base.
- Realtime se usara para invalidar/refrescar consultas puntuales, no para reconstruir toda la app.

## Decisiones Cerradas

- Habra un usuario admin principal.
- Los usuarios se registran con email y quedan sin permisos hasta que el admin los habilite.
- El uso normal sera de un usuario, pero el modelo queda preparado para varios usuarios concurrentes.
- Se conserva estructura de organizacion unica: multiempresa real no se implementa ahora, pero todas las tablas operativas mantienen `organization_id` para RLS y permisos.
- Punta del Este es una seccion separada de Alquileres Urbanos.
- Los departamentos PDE `209` y `601` no pertenecen al modelo de edificios urbanos.
- No se borran datos criticos fisicamente como regla general: se archivan, cancelan o anulan.
- La UI puede mostrar "Eliminar" para `owner/admin`, pero la operacion interna sera archivar/anular con auditoria.
- Los comprobantes, contratos y documentos se guardan como archivos reales en Supabase Storage.
- La liquidacion familiar se cierra congelada, con snapshot, y puede corregirse/editase luego con auditoria.
- Las liquidaciones familiares corregidas se versionan: no se pisa el snapshot original.
- Los importes se guardan como `numeric`, nunca como float.
- Las fechas puras de negocio usan `date`; los instantes reales usan `timestamptz`.
- La zona horaria operativa es `America/Argentina/Buenos_Aires`.

## Decisiones Arquitectonicas Cerradas

### Organizacion

El sistema nace para una sola administracion/familia, pero mantiene `organizations` y `organization_members`.

- La organizacion inicial sera `El Cometa`.
- No se implementa multiempresa en UI ni flujos de negocio por ahora.
- Todas las tablas de negocio tendran `organization_id`.
- RLS se define desde el inicio por organizacion y membresia activa.
- Esta decision evita reescribir seguridad cuando haya mas usuarios.

### Estados Almacenados Vs Calculados

Criterio:

- Almacenar estados cuando representan una decision humana, simplifican una operacion critica, necesitan historial o deben congelarse.
- Calcular valores cuando salen directamente de cargos, pagos, fechas o asignaciones confirmadas.

Estados almacenados con actualizacion controlada por RPC:

- `urban_units.status`
- `urban_charges.status`
- `urban_leases.status`
- `pde_reservations.status`
- `family_settlements.status`
- `files.status`

Valores derivados que no deben ser enviados por el frontend como autoridad:

- saldo urbano.
- saldo PDE.
- total de cargo urbano.
- estado final de cargo luego de un cobro.
- estado final de reserva PDE luego de un cobro/anulacion.
- valor por noche PDE.
- margenes y totales de reportes.

### Liquidaciones Familiares Corregidas

Las correcciones crean una nueva version vigente.

- `family_settlements.version` indica la version.
- `family_settlements.corrects_settlement_id` apunta a la version corregida.
- `family_settlements.is_current` indica cual se consulta por defecto.
- La version anterior pasa a estado `corrected`.
- La nueva version queda `closed` e `is_current = true`.
- El motivo y usuario de la correccion quedan auditados.

### Carga De Archivos

La operacion de negocio no debe depender de que el archivo suba correctamente.

Flujo recomendado:

1. Crear/confirmar la operacion de negocio.
2. Subir archivo a Storage.
3. Crear `files`.
4. Crear `file_links`.

Si falla la subida:

- La operacion queda confirmada sin comprobante.
- El comprobante se puede cargar despues.

Si se sube el archivo pero falla el vinculo:

- El archivo queda `pending_link`.
- Se puede reintentar el vinculo o marcar `orphaned`.
- Un proceso administrativo puede limpiar archivos huerfanos.

Estados sugeridos para `files`:

- `pending_link`
- `active`
- `archived`
- `orphaned`

### Monedas Y Periodos

Monedas iniciales:

- `ARS`
- `USD`

Reglas:

- Urbanos puede operar en ARS o USD segun contrato/cargo.
- Expensas urbanas arrancan en ARS.
- PDE arranca en USD por defecto.
- No hay conversion automatica en la primera etapa.
- Si una liquidacion futura requiere conversion, se guarda snapshot de `exchange_rate`, `exchange_rate_date` y `exchange_rate_source`.

Tipos:

- Importes: `numeric(14,2)` o `numeric(16,2)` segun tabla.
- Periodo mensual de expensas: `period_month date`, siempre dia 1.
- Liquidaciones: `period_start date` y `period_end date`.
- Fechas de ingreso/egreso y vencimientos: `date`.
- Creacion, actualizacion y auditoria: `timestamptz`.

## Modulos

1. Autenticacion y permisos
2. Alquileres Urbanos
3. Expensas
4. Cobros urbanos
5. Liquidaciones familiares
6. Mantenimiento
7. Punta del Este
8. Calendarios y notas
9. Archivos/comprobantes
10. Auditoria

## Roles

- `owner`: control total, administra usuarios y configuracion.
- `admin`: administra datos de negocio y usuarios operativos.
- `editor`: carga y modifica operaciones normales.
- `viewer`: solo lectura.

Regla: la interfaz puede ocultar botones, pero la seguridad real vive en RLS y RPCs.

## Entidades Y Tablas Propuestas

### Base Organizacional

`organizations`
- Empresa/organizacion del sistema.
- Fuente de verdad del scope multiusuario.

`profiles`
- Perfil conectado a `auth.users`.
- Guarda nombre visible, email y estado.

`organization_members`
- Relacion usuario-organizacion.
- Campos: `organization_id`, `user_id`, `role`, `status`.
- Estados sugeridos: `pending`, `active`, `disabled`.
- Solo `owner/admin` puede activar y asignar rol.

### Contactos

`contacts`
- Personas y empresas: inquilinos, huespedes, proveedores, profesionales, beneficiarios familiares.
- Campos de busqueda: nombre, apellido, razon social, telefono, email, documento.
- Flags: `is_tenant`, `is_guest`, `is_provider`, `is_worker`, `is_family_beneficiary`.
- No duplicar un contacto si puede cumplir mas de un rol.

### Alquileres Urbanos

`urban_buildings`
- Edificios urbanos.
- Campos: nombre, direccion, `has_expenses`, estado.
- Estados: `active`, `archived`.

`urban_units`
- Departamentos urbanos.
- Pertenece a `urban_buildings`.
- Campos: nombre, superficie, estado, observaciones.
- Estados: `available`, `rented`, `maintenance`, `archived`.
- La superficie se usa para calcular expensas.

`urban_leases`
- Contratos/alquileres fijos.
- Pertenece a una unidad.
- Relaciona inquilino principal via `contact_id`.
- Campos: fechas, monto actual, moneda, dia de vencimiento, frecuencia de ajuste, proximo ajuste.
- Estados: `upcoming`, `active`, `finalized`, `rescinded`, `archived`.
- Debe impedir contratos activos solapados para la misma unidad.

`urban_lease_adjustments`
- Historial de cambios de monto.
- Guarda monto anterior, monto nuevo, fecha efectiva, usuario y notas.

### Cargos Y Cobros Urbanos

`urban_charges`
- Cargos por periodo para una unidad/contrato.
- No es solo alquiler: es el encabezado del vencimiento.
- Estados: `pending`, `partial`, `paid`, `cancelled`.
- Unique sugerido: contrato + periodo.

`urban_charge_items`
- Detalle del cargo.
- Tipos: `rent`, `rent_surcharge`, `building_expense`, `expense_surcharge`, `unit_expense`, `rescission`, `other`.
- El total del cargo es derivado de sus items.

`urban_payments`
- Cobros reales.
- Campos: fecha, importe, moneda, metodo, estado, observaciones.
- Estados: `valid`, `voided`.
- No debe guardar saldo final como autoridad.

`urban_payment_allocations`
- Imputacion de un cobro a items de cargo.
- Permite saber cuanto fue a alquiler, recargo de alquiler, expensas, recargo de expensas, etc.
- La suma imputada no puede superar el importe cobrado ni el saldo del item.

### Expensas

`expense_categories`
- Rubros configurables.
- Para PDE inicialmente: Expensas, Limpieza, UTE, Primarias, Contribucion Inmobiliaria, Administracion, Mantenimiento, Otros.
- Para urbanos puede ampliarse por edificio.

`urban_expense_periods`
- Periodo de expensas por edificio.
- Estados: `draft`, `calculated`, `closed`, `cancelled`.

`urban_expense_items`
- Gastos cargados en un periodo.
- Campos: categoria, detalle, fecha, importe, comprobante opcional, criterio de traslado.
- Estados: `valid`, `voided`.

`urban_expense_allocations`
- Resultado de distribuir gastos por superficie.
- Snapshot de superficie de la unidad y total del edificio al momento de calcular.
- Puede generar items en `urban_charge_items`.

### Liquidacion Familiar

`family_distribution_groups`
- Configuracion de distribucion por unidad y vigencia.
- Evita pisar historicos.

`family_distribution_shares`
- Beneficiario + porcentaje.
- La suma por grupo activo debe ser 100%.

`family_settlements`
- Liquidacion cerrada por periodo.
- Estados: `draft`, `closed`, `corrected`, `cancelled`.
- Guarda totales congelados ARS/USD.

`family_settlement_items`
- Snapshot de cada pago incluido, unidad, beneficiario, porcentaje e importe.
- No depende de recalcular a futuro con porcentajes nuevos.

`family_settlement_corrections`
- Correcciones posteriores a una liquidacion cerrada.
- Guarda motivo, usuario y cambios relevantes.

### Mantenimiento

`maintenance_tasks`
- Tareas por departamento urbano.
- Estados: `open`, `finished`, `cancelled`.
- Campos: titulo, detalle, profesional, fechas.

`maintenance_expenses`
- Gastos dentro de una tarea.
- Campos: concepto, fecha, importe, comprobante, estado.
- Estados: `valid`, `voided`.

### Punta Del Este

`pde_units`
- Unidades temporarias independientes.
- Inicialmente `209` y `601`.
- Campos: nombre, descripcion opcional, estado.
- Estados: `active`, `archived`.

`pde_reservations`
- Reservas temporarias.
- Pertenece a `pde_units`.
- Campos: huesped, fecha ingreso, fecha egreso, noches, total, moneda, estado.
- Estados: `reserved`, `deposit_received`, `paid`, `cancelled`, `finished`.
- Noches y valor por noche son derivados desde fechas y total.
- Debe impedir solapamiento de reservas activas en la misma unidad.

`pde_reservation_payments`
- Cobros de reservas.
- Tipos: `deposit`, `balance`, `other`.
- Estados: `valid`, `voided`.
- El estado de la reserva se determina desde pagos confirmados.

`pde_expenses`
- Gastos PDE.
- Puede aplicar a `209`, `601` o `general_50_50`.
- Campos: rubro, detalle, fecha, importe, comprobante, estado.
- Si es general, PostgreSQL debe dividir 50/50 mediante registros derivados o allocations.

`pde_expense_allocations`
- Resultado de asignar gasto PDE a una unidad.
- Para gasto general guarda dos filas, una por cada unidad.

### Calendarios

`calendar_notes`
- Notas manuales.
- Scope: `urban`, `pde`, `general`.
- No reemplaza vencimientos ni reservas, solo eventos manuales.

### Archivos

`files`
- Metadata del archivo en Storage.
- Campos: bucket, path, nombre original, mime, size, usuario, estado.
- Estados: `active`, `archived`.

`file_links`
- Relaciona archivo con entidad.
- Entidades: contrato, cobro urbano, gasto expensas, mantenimiento, reserva PDE, cobro PDE, gasto PDE, liquidacion.

### Auditoria

`audit_logs`
- Guarda operaciones importantes.
- Campos: usuario ejecutor, accion, entidad afectada, entidad_id, operation_id, valores antes/despues relevantes, fecha, request_id.
- No se audita todo automaticamente si no aporta valor, pero si toda operacion critica.

`operation_results`
- Guarda el resultado confirmado de cada operacion idempotente.
- Campos: organizacion, operation_id, tipo de operacion, hash de entrada, estado, entidad_resultado, payload_resultado, error, usuario ejecutor, fechas.
- Permite devolver el mismo resultado ante reintentos seguros y rechazar reintentos con datos distintos.

## Fuente De Verdad

- Saldo urbano: `urban_charge_items` menos `urban_payment_allocations`.
- Estado de cargo: derivado de items e imputaciones, o actualizado por RPC luego de validar.
- Total de cobro: `urban_payments.received_amount`.
- Total de cargo: suma de `urban_charge_items`.
- Expensas liquidadas: `urban_expense_allocations` y items generados.
- Liquidacion familiar cerrada: `family_settlement_items` congelados.
- Saldo PDE: pagos validos de reservas menos gastos PDE asignados.
- Estado reserva PDE: pagos validos contra total, cancelacion y fecha de salida.
- Valor por noche PDE: total / noches.
- Reportes: consultas/agregados desde movimientos confirmados.

## Escrituras Seguras Como Insert/Update Directo

Solo si RLS lo permite y no afectan saldos ni estados derivados criticos:

- Crear nota de calendario.
- Editar nota de calendario.
- Archivar nota.
- Crear contacto simple.
- Editar datos basicos de contacto.
- Crear categoria/rubro.
- Editar descripcion de archivo.

Incluso estas escrituras deben guardar `organization_id`, `created_by`, timestamps y respetar RLS.

## Operaciones Que Deben Ser RPC

Prioridad alta:

- `claim_initial_owner`
- `request_organization_access`
- `enable_member`
- `disable_member`
- `create_urban_building`
- `archive_urban_building`
- `create_urban_unit`
- `archive_urban_unit`
- `create_urban_lease`
- `finalize_urban_lease`
- `adjust_urban_rent`
- `generate_urban_charge`
- `register_urban_payment`
- `void_urban_payment`
- `create_urban_expense_period`
- `add_urban_expense_item`
- `void_urban_expense_item`
- `calculate_urban_expense_allocations`
- `close_family_settlement`
- `correct_family_settlement`
- `create_pde_reservation`
- `update_pde_reservation`
- `cancel_pde_reservation`
- `register_pde_payment`
- `void_pde_payment`
- `register_pde_expense`
- `void_pde_expense`
- `create_file_link`

Prioridad media:

- `create_maintenance_task`
- `finish_maintenance_task`
- `add_maintenance_expense`
- `void_maintenance_expense`
- `update_distribution_group`

## Reglas Para RPCs Criticas

Cada RPC critica debe:

1. Validar `auth.uid()`.
2. Validar membresia activa en la organizacion.
3. Validar rol/permisos.
4. Validar datos de entrada.
5. Bloquear filas relevantes si hay riesgo de concurrencia.
6. Ejecutar todos los cambios en una transaccion.
7. Registrar auditoria.
8. Devolver el resultado confirmado.
9. Hacer rollback completo si algo falla.

## Concurrencia

Operaciones con control fuerte:

- Crear reserva PDE: impedir solapamientos por unidad.
- Actualizar reserva PDE: revalidar solapamientos.
- Registrar cobro urbano: evitar sobreimputar cargo.
- Registrar cobro PDE: evitar pagos duplicados/superiores al saldo.
- Calcular expensas: evitar recalcular/cerrar dos veces el mismo periodo.
- Cerrar liquidacion familiar: evitar dos cierres del mismo periodo.
- Crear contrato urbano: impedir contratos activos solapados.
- Archivar unidad/edificio: validar dependencias activas.

Herramientas:

- constraints y unique indexes.
- exclusion constraints para rangos de fechas.
- `select ... for update` dentro de RPCs.
- estados `closed/cancelled/voided`.
- `operation_id` en operaciones con riesgo de retry.

### Restricciones De Solapamiento En PostgreSQL

Las validaciones de solapamiento no deben depender solo del frontend ni solo de una consulta previa dentro de una RPC. PostgreSQL debe tener una restriccion final que impida estados incompatibles aunque dos usuarios operen al mismo tiempo.

Reservas PDE:

- Activar `btree_gist`.
- Usar exclusion constraint por `unit_id` y rango de fechas.
- Modelo conceptual: una unidad no puede tener dos reservas activas cuyo rango `daterange(start_date, end_date, '[)')` se superponga.
- La restriccion debe ignorar reservas canceladas, anuladas o archivadas.

Contratos urbanos:

- Una unidad urbana no puede tener contratos activos/vigentes con periodos superpuestos.
- La restriccion debe aplicar solo a contratos que tengan efecto real, no a borradores, anulados o archivados.

La RPC igualmente debe validar antes para devolver mensajes claros al usuario, pero la constraint es la garantia final de consistencia.

## Idempotencia

Agregar `operation_id` en:

- cobros urbanos.
- anulacion de cobros urbanos.
- calculo/cierre de expensas.
- cierre/correccion de liquidacion familiar.
- creacion de reserva PDE.
- cobros PDE.
- gastos PDE.
- carga de archivos vinculada a operacion critica.

Unique sugerido: `organization_id + operation_id`.

Modelo sugerido: `operation_results`.

Campos clave:

- `organization_id`
- `operation_id`
- `operation_type`
- `request_hash`
- `status`: `in_progress`, `succeeded`, `failed`
- `result_entity_type`
- `result_entity_id`
- `result_payload`
- `error_code`
- `created_by`
- `created_at`
- `completed_at`

Reglas:

- Si llega el mismo `operation_id` con el mismo `request_hash`, devolver el resultado ya guardado.
- Si llega el mismo `operation_id` con otro `request_hash`, rechazar la operacion.
- Si la operacion esta `in_progress`, bloquear la fila con `select ... for update` o devolver estado pendiente segun corresponda.
- El resultado se confirma en la misma transaccion que la operacion de negocio.
- Si la transaccion falla, no debe quedar una operacion marcada como exitosa.

## Lecturas Desde Supabase

No descargar tablas completas para filtrar en JavaScript.

Consultas/RPCs sugeridas:

- `get_urban_overview()`
- `get_urban_buildings_with_units()`
- `get_urban_pending_charges_page(filters, page, page_size)`
- `get_urban_payments_page(filters, page, page_size)`
- `get_unit_account_statement(unit_id, filters)`
- `get_expense_period_detail(building_id, period)`
- `get_family_settlements_page(filters, page, page_size)`
- `get_family_settlement_detail(settlement_id)`
- `get_maintenance_history_page(unit_id, filters, page, page_size)`
- `get_pde_calendar(month, year)`
- `get_pde_pending_reservations(filters, page, page_size)`
- `get_pde_reservation_history(filters, page, page_size)`
- `get_pde_movements_page(filters, page, page_size)`
- `get_urban_report_summary(period_filter)`
- `get_pde_report_summary(period_filter)`
- `get_calendar_events(scope, month, year)`

Filtros frecuentes:

- fecha desde/hasta.
- mes/anio.
- edificio.
- departamento.
- inquilino/huesped.
- tipo de movimiento.
- estado.
- rubro.
- metodo de pago.

## Indices Principales

- `organization_members(user_id, organization_id)`.
- `urban_buildings(organization_id, status)`.
- `urban_units(organization_id, building_id, status)`.
- `urban_leases(unit_id, status, start_date, end_date)`.
- `urban_charges(organization_id, unit_id, period_month, status)`.
- `urban_payments(organization_id, payment_date, status)`.
- `urban_expense_periods(building_id, period_month)`.
- `family_settlements(organization_id, period_start, period_end, status)`.
- `pde_reservations(unit_id, start_date, end_date, status)`.
- `pde_reservation_payments(reservation_id, payment_date, status)`.
- `pde_expenses(organization_id, expense_date, unit_id, status)`.
- `files(organization_id, bucket, storage_path)`.
- `audit_logs(organization_id, occurred_at desc)`.
- `audit_logs(organization_id, operation_id)`.
- `operation_results(organization_id, operation_id)` unico.

Agregar indices de busqueda solo sobre campos realmente usados.

## RLS

Regla base:

- Todas las tablas con `organization_id` tienen RLS por membresia activa.
- `viewer` puede leer.
- `editor` puede operar escrituras normales por RPC.
- `admin/owner` puede administrar usuarios, archivar entidades y corregir liquidaciones.
- Las operaciones criticas se exponen preferentemente por RPC y no por permisos amplios de tabla.

Funciones de seguridad:

- `is_org_member(organization_id)`
- `has_org_role(organization_id, roles[])`
- `current_user_profile()`

Si se usa `security definer`:

- fijar `search_path`.
- validar `auth.uid()`.
- validar organizacion y rol.
- no aceptar IDs arbitrarios sin verificar pertenencia.

## Storage

Buckets privados:

- `contracts`
- `receipts`
- `maintenance`
- `settlements`

Paths sugeridos:

- `org/{organization_id}/contracts/{lease_id}/{file_id}`
- `org/{organization_id}/receipts/urban-payments/{payment_id}/{file_id}`
- `org/{organization_id}/receipts/pde-payments/{payment_id}/{file_id}`
- `org/{organization_id}/receipts/pde-expenses/{expense_id}/{file_id}`
- `org/{organization_id}/maintenance/{task_id}/{file_id}`
- `org/{organization_id}/settlements/{settlement_id}/{file_id}`

Los archivos privados se acceden con signed URLs generadas por backend/Supabase segun permisos.

La migracion `003_storage_and_access_rpcs.sql` crea estos buckets como privados y restringe `storage.objects` por path:

```text
org/{organization_id}/...
```

No se habilita borrado fisico de objetos desde el cliente. Si un comprobante deja de corresponder, se marca `files.status = archived` u `orphaned` segun el caso.

## Acceso Inicial Y Usuarios

RPCs base:

- `claim_initial_owner(organization_id)`: permite que el primer usuario autenticado tome el rol `owner` si todavia no hay miembros activos.
- `request_organization_access(organization_id)`: crea/actualiza el perfil y deja la membresia en `pending`.
- `enable_member(organization_id, user_id, role)`: `owner/admin` habilita un usuario y define rol.
- `disable_member(organization_id, user_id)`: `owner/admin` deshabilita un usuario sin borrarlo.
- `get_my_memberships()`: devuelve las organizaciones y roles del usuario autenticado.

El alta normal queda asi:

1. Usuario se registra con email.
2. Usuario pide acceso a `El Cometa`.
3. Admin/dueño habilita y asigna rol.
4. El frontend muestra opciones segun rol, pero la seguridad real queda en RLS/RPC.

## Auditoria

Auditar:

- altas, cambios y archivos de contratos.
- ajustes de alquiler.
- cobros y anulaciones.
- calculo/cierre/cancelacion de expensas.
- cierre/correccion de liquidaciones familiares.
- reservas PDE, cambios y cancelaciones.
- cobros/gastos PDE y anulaciones.
- archivos vinculados.
- cambios de roles/usuarios.
- archivado de edificios/unidades.

No auditar cada lectura ni cada cambio visual.

Cada registro de auditoria debe diferenciar claramente:

- `actor_user_id`: usuario que ejecuto la accion.
- `entity_type`: tipo de entidad afectada.
- `entity_id`: identificador de la entidad afectada.
- `operation_id`: identificador comun de la operacion completa.
- `action`: alta, modificacion, anulacion, archivo, cierre, correccion, vinculacion de archivo, etc.
- `old_values` y `new_values`: solo campos relevantes para investigar cambios.
- `metadata`: contexto adicional no critico.

Una misma operacion puede generar varios registros de auditoria. Por ejemplo, registrar un cobro puede crear el cobro, imputarlo a cargos, cambiar estados derivados y vincular un comprobante, todo agrupado bajo el mismo `operation_id`.

## Cache Futuro

No implementar cache hasta tener lecturas estables.

Formato conceptual:

```text
query_key = recurso + filtros + pagina + usuario/organizacion
```

Ejemplos:

- `urban_payments:org:period:page:filters`
- `pde_reservations:month:unit`
- `urban_dashboard:period`

El cache se invalida por operacion confirmada o evento Realtime.

## Realtime Futuro

Usar solo para invalidacion selectiva.

Candidatos:

- `urban_payments`
- `urban_charges`
- `pde_reservations`
- `pde_reservation_payments`
- `pde_expenses`
- `calendar_notes`

Flujo:

```text
Supabase cambia
Realtime avisa
se marca query vieja
refetch selectivo
UI actualiza
```

No usar Realtime para descargar toda la base.

## No Aplica A Este Sistema

Quedan excluidos del alcance:

- stock.
- productos.
- compras.
- ventas comerciales.
- taller.
- cierres de caja.

Los equivalentes criticos aca son:

- cobros.
- gastos.
- reservas.
- expensas.
- liquidaciones.
- contratos.
- comprobantes.

## Proximo Paso

El contrato ya se bajo a una primera migracion limpia en `supabase/migrations/001_initial_rentals_schema.sql`.

Siguientes pasos tecnicos:

1. Validar la migracion contra un proyecto Supabase/local PostgreSQL.
2. Ajustar cualquier detalle de sintaxis o permisos detectado por Supabase.
3. Crear RPCs transaccionales de prioridad alta.
4. Conectar las primeras lecturas paginadas desde el frontend.
5. Recien despues conectar formularios de escritura y carga de archivos.

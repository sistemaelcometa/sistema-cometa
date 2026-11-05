# El Cometa agricola

Aplicar una vez en Supabase la migracion `074_cometa_agricultural_movements.sql`.
El modulo tiene sus propias tablas, permisos y auditoria. No agrega movimientos a los reportes de Alquileres.

Ingresos: Ventas de cereal, Ventas de bienes de uso.
Egresos: Combustible (ciudad), Insumos (incluye combustible para labores de campo),
Gastos de comercializacion, Reparaciones, Gastos varios, Alquileres y Seguros.
Los importes admiten centavos. Pesos argentinos y dolares se muestran por separado sin conversion.
Los filtros se aplican tanto a la tabla como a los totales y al grafico; la paginacion afecta solo a las filas.
Los movimientos anulados conservan el comprobante y la auditoria.

## Lectura opcional de facturas

Por decision del usuario, la lectura automatica queda postergada y desactivada por defecto.
El formulario muestra la carga manual y permite adjuntar una foto o PDF.
Tener una clave configurada no activa la funcion por si solo.

En el servidor de produccion (por ejemplo, variables de entorno de Vercel), configurar:

- `OPENAI_API_KEY`: clave privada de la API de OpenAI. Nunca usar un prefijo `NEXT_PUBLIC_`.
- `OPENAI_INVOICE_MODEL`: opcional; por defecto `gpt-4.1-mini`.
- `COMETA_INVOICE_AI_ENABLED=true`: solo cuando se decida retomar la funcion. Por defecto esta desactivada.

Volver a desplegar despues de configurar las variables. La API requiere una cuenta con
acceso y facturacion habilitados. La suscripcion de ChatGPT no configura esta integracion.
La clave nunca se ingresa en el formulario ni se envia al navegador.

El usuario elige Sacar foto o Cargar PDF o imagen y luego Leer factura.
La lectura solo genera un borrador. El usuario puede corregir cualquier campo y debe
marcar la confirmacion de revision antes de guardar. La IA no registra dinero.
Sin clave, o si falla la lectura, se puede adjuntar el comprobante y completar los datos manualmente.

Archivos admitidos: PDF, JPG, PNG y WebP, hasta 20 MB para adjuntar y hasta 3 MB para lectura automatica.
Las imagenes se optimizan en el navegador usando la misma compresion del resto de la app.
Los comprobantes se guardan en el bucket privado existente `receipts`, bajo la organizacion y
la operacion del movimiento. La lectura usa URLs firmadas de corta duracion.

Implementacion basada en la documentacion oficial:
[archivos](https://developers.openai.com/api/docs/guides/file-inputs),
[salidas estructuradas](https://developers.openai.com/api/docs/guides/structured-outputs).

# Recordatorio mensual: Pagar Santiago

Aplicar `supabase/migrations/087_monthly_payment_reminder.sql` antes de desplegar.
El cartel aparece en todas las secciones del sistema, despues de iniciar sesion,
desde el dia 5 de cada mes y hasta que se posponga o se marque como pagado.

- **Posponer hasta manana** lo oculta hasta el siguiente dia calendario de Argentina.
- **Marcar como pagado** lo oculta durante el resto del mes. El proximo mes vuelve el dia 5.

El estado se guarda en Supabase por organizacion y mes, y se comparte entre usuarios.
Se conserva al recargar, cambiar de seccion, cerrar sesion o usar otro dispositivo.
Dueños, administradores y editores pueden actualizarlo. Los usuarios de solo lectura
ven el aviso sin acciones. No se crea un pago ni un ingreso/egreso en ningun subsistema.

La fecha se calcula en el servidor con la zona horaria de Argentina. Posponer un dia
no significa esperar 24 horas exactas. El cambio de mes se valida para impedir que una
pestana vieja marque por error el mes siguiente; pagado prevalece sobre un posponer tardio.
La lectura se actualiza al entrar, volver a la ventana, cambiar de dia, mediante Realtime
y una comprobacion por minuto cuando la pagina esta visible. No requiere cron ni servicios de IA.

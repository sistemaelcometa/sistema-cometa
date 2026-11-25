"use client";
import * as React from "react";
import {BellRing} from "lucide-react";
import {supabase} from "@/lib/supabase/client";
import {watchArgentinaDay} from "@/lib/argentina-day";

type ReminderState={title:string;period_month:string;today:string;due_date:string;snoozed_until:string|null;paid_at:string|null;visible:boolean};

export function MonthlyPaymentReminder({organization,canWrite}:{organization:string;canWrite:boolean}){
 const [reminder,setReminder]=React.useState<ReminderState|null>(null),[error,setError]=React.useState(''),[busy,setBusy]=React.useState(false);
 const mounted=React.useRef(false),working=React.useRef(false),sequence=React.useRef(0);
 const refresh=React.useCallback(async()=>{
  if(!supabase||working.current)return;
  const ticket=++sequence.current;
  try{const result=await supabase.rpc('get_monthly_payment_reminder',{target_organization_id:organization});if(result.error)throw result.error;if(mounted.current&&ticket===sequence.current){setReminder(result.data as ReminderState);setError('')}}
  catch{if(mounted.current&&ticket===sequence.current)setError('No se pudo cargar el recordatorio de pago. Volvé a intentar.')}
 },[organization]);
 React.useEffect(()=>{
  mounted.current=true;void refresh();
  const onFocus=()=>{if(!document.hidden)void refresh()};
  const unwatch=watchArgentinaDay(()=>void refresh());
  window.addEventListener('focus',onFocus);document.addEventListener('visibilitychange',onFocus);
  const interval=window.setInterval(onFocus,60_000);
  const channel=supabase?.channel('monthly-reminder:'+organization).on('postgres_changes',{event:'*',schema:'public',table:'monthly_payment_reminder_states',filter:'organization_id=eq.'+organization},()=>void refresh()).subscribe();
  return()=>{mounted.current=false;sequence.current++;unwatch();window.clearInterval(interval);window.removeEventListener('focus',onFocus);document.removeEventListener('visibilitychange',onFocus);if(channel)void supabase?.removeChannel(channel)};
 },[organization,refresh]);
 async function act(action:'snooze'|'paid'){
  if(!supabase||!reminder||!canWrite||working.current)return;
  working.current=true;sequence.current++;setBusy(true);setError('');
  try{const result=await supabase.rpc('update_monthly_payment_reminder',{target_organization_id:organization,target_period_month:reminder.period_month,reminder_action:action});if(result.error)throw result.error;if(mounted.current)setReminder(result.data as ReminderState)}
  catch(err){if(mounted.current)setError((err as {message?:string}).message||'No se pudo guardar. Volvé a intentar.')}
  finally{working.current=false;if(mounted.current)setBusy(false)}
 }
 if(!reminder?.visible&&!error)return null;
 return <section className="monthly-payment-reminder" aria-label="Recordatorio de pago"><div className="monthly-reminder-copy"><BellRing size={28} aria-hidden="true"/><div>{reminder?.visible&&<><h3>{reminder.title}</h3><p>Recordatorio mensual · Desde el día 5</p></>}{error&&<p role="alert">{error}</p>}</div></div><div className="monthly-reminder-actions">{reminder?.visible&&canWrite&&<><button className="secondary-button" disabled={busy} onClick={()=>void act('snooze')}>Posponer hasta mañana</button><button className="primary-button" disabled={busy} onClick={()=>void act('paid')}>{busy?'Guardando...':'Marcar como pagado'}</button></>}{error&&<button className="small-button" disabled={busy} onClick={()=>void refresh()}>Actualizar recordatorio</button>}</div></section>;
}

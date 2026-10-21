import assert from 'node:assert/strict';
import test from 'node:test';
import { getPdeAvailability, validateAvailabilityWindow } from '../lib/pde-availability-dates.ts';

const reservation = (from,to,unit='209',status='Reservada') => ({unit,from,to,status});
const periods = (reservations,from='2027-01-01',to='2027-01-31') => getPdeAvailability(['209'],reservations,from,to)[0].periods;

test('month query lists every free period separately for each department and includes the final day', () => {
  const rows=getPdeAvailability(['209','601'],[
    reservation('2027-01-10','2027-01-15'), reservation('2027-01-20','2027-01-25'),
    reservation('2027-01-01','2027-01-31','601'),
  ],'2027-01-01','2027-01-31');
  assert.deepEqual(rows[0].periods,[
    {from:'2027-01-01',through:'2027-01-09',days:9},
    {from:'2027-01-15',through:'2027-01-19',days:5},
    {from:'2027-01-25',through:'2027-01-31',days:7},
  ]);
  assert.deepEqual(rows[1].periods,[{from:'2027-01-31',through:'2027-01-31',days:1}]);
});

test('empty and completely occupied departments still have their own result', () => {
  assert.deepEqual(periods([]),[{from:'2027-01-01',through:'2027-01-31',days:31}]);
  assert.deepEqual(periods([reservation('2026-12-01','2027-02-01')]),[]);
  assert.deepEqual(getPdeAvailability([],[],'2027-01-01','2027-01-31'),[]);
});

test('overlapping, nested and adjacent reservations merge without false free gaps', () => {
  assert.deepEqual(periods([
    reservation('2027-01-15','2027-01-25'), reservation('2027-01-10','2027-01-20'),
    reservation('2027-01-12','2027-01-14'), reservation('2027-01-25','2027-01-28'),
  ]),[
    {from:'2027-01-01',through:'2027-01-09',days:9},
    {from:'2027-01-28',through:'2027-01-31',days:4},
  ]);
});

test('reservations crossing the query boundaries are clipped; checkout day is free', () => {
  assert.deepEqual(periods([
    reservation('2026-12-20','2027-01-05'), reservation('2027-01-28','2027-02-10'),
    reservation('2026-12-01','2027-01-01'), reservation('2027-02-01','2027-02-10'),
  ]),[{from:'2027-01-05',through:'2027-01-27',days:23}]);
});

test('cancelled bookings do not block days, while reservations with incomplete dates cannot yield false availability', () => {
  assert.deepEqual(periods(['Cancelada','cancelled','canceled'].map(status=>reservation('2027-01-01','2027-02-01','209',status))),
    [{from:'2027-01-01',through:'2027-01-31',days:31}]);
  const result=getPdeAvailability(['209'],[reservation('','2027-02-01')],'2027-01-01','2027-01-31')[0];
  assert.equal(result.invalidReservations,true);
  assert.deepEqual(result.periods,[]);
});

test('query supports a single day and rejects incomplete, impossible or reversed dates without rewriting them', () => {
  assert.deepEqual(validateAvailabilityWindow('2027-01-10','2027-01-10'),{valid:true,message:''});
  assert.deepEqual(periods([],'2027-01-10','2027-01-10'),[{from:'2027-01-10',through:'2027-01-10',days:1}]);
  assert.deepEqual(periods([reservation('2027-01-10','2027-01-11')],'2027-01-10','2027-01-10'),[]);
  for(const [from,to] of [['','2027-01-31'],['0002-01-01','2027-01-31'],['2027-02-29','2027-03-01'],['2027-01-10','2027-01-09']]){
    assert.equal(validateAvailabilityWindow(from,to).valid,false);
    assert.deepEqual(getPdeAvailability(['209'],[],from,to),[]);
  }
});

test('day counts remain exact across leap days, year boundaries and daylight saving changes', () => {
  for(const [from,to,days] of [['2028-02-28','2028-03-01',3],['2026-12-31','2027-01-02',3],['2027-03-13','2027-03-15',3]]){
    assert.deepEqual(periods([],from,to),[{from,through:to,days}]);
  }
});

test('interval sweep matches a day-by-day reference and does not mutate reservations', () => {
  const date=day=>new Date(Date.UTC(2027,0,day)).toISOString().slice(0,10);
  for(let seed=0;seed<50;seed++){
    const reservations=Array.from({length:12},(_,i)=>{
      const start=((seed*7+i*11)%46)-5;
      return reservation(date(start),date(start+(i%8)+1));
    });
    const before=structuredClone(reservations), free=periods(reservations);
    const actual=Array.from({length:31},(_,i)=>date(i+1)).filter(day=>free.some(part=>part.from<=day&&day<=part.through));
    const expected=Array.from({length:31},(_,i)=>date(i+1)).filter(day=>!reservations.some(item=>item.from<=day&&day<item.to));
    assert.deepEqual(actual,expected);
    assert.deepEqual(reservations,before);
    assert.equal(free.reduce((sum,part)=>sum+part.days,0),expected.length);
  }
});

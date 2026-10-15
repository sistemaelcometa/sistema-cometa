"use client";

import { ChevronLeft, ChevronRight } from "lucide-react";

type CalendarPeriodControlsProps = {
  value: Date;
  onChange: (value: Date) => void;
  months: string[];
};

export function CalendarPeriodControls({ value, onChange, months }: CalendarPeriodControlsProps) {
  const year = value.getFullYear();
  const month = value.getMonth();
  const firstYear = 2020;
  const lastYear = 2040;

  return (
    <div className="month-controls calendar-select-controls calendar-steppers">
      <div className="calendar-period-stepper">
        <button className="calendar-step-button" type="button" aria-label="Mes anterior" title="Mes anterior"
          disabled={year === firstYear && month === 0} onClick={() => onChange(new Date(year, month - 1, 1))}>
          <ChevronLeft size={16} aria-hidden="true" />
        </button>
        <select className="calendar-period-select" value={month} aria-label="Mes"
          onChange={event => onChange(new Date(year, Number(event.target.value), 1))}>
          {months.map((label, index) => <option value={index} key={label}>{label}</option>)}
        </select>
        <button className="calendar-step-button" type="button" aria-label="Mes siguiente" title="Mes siguiente"
          disabled={year === lastYear && month === 11} onClick={() => onChange(new Date(year, month + 1, 1))}>
          <ChevronRight size={16} aria-hidden="true" />
        </button>
      </div>
      <div className="calendar-period-stepper">
        <button className="calendar-step-button" type="button" aria-label="Año anterior" title="Año anterior"
          disabled={year === firstYear} onClick={() => onChange(new Date(year - 1, month, 1))}>
          <ChevronLeft size={16} aria-hidden="true" />
        </button>
        <select className="calendar-period-select year-select" value={year} aria-label="Año"
          onChange={event => onChange(new Date(Number(event.target.value), month, 1))}>
          {Array.from({ length: lastYear - firstYear + 1 }, (_, index) => firstYear + index)
            .map(option => <option value={option} key={option}>{option}</option>)}
        </select>
        <button className="calendar-step-button" type="button" aria-label="Año siguiente" title="Año siguiente"
          disabled={year === lastYear} onClick={() => onChange(new Date(year + 1, month, 1))}>
          <ChevronRight size={16} aria-hidden="true" />
        </button>
      </div>
    </div>
  );
}

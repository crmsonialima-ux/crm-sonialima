import { ChevronLeft, ChevronRight, Calendar } from "lucide-react";

export type DashboardFilterState = {
  allTime: boolean;
  year: number;
  month: number;
};

const FILTER_STORAGE_KEY = "crm_dashboard_filter";

export function getInitialFilterState(email?: string | null): DashboardFilterState {
  if (email === "unassigned-institutional@example.invalid") {
    return {
      allTime: true,
      year: new Date().getFullYear(),
      month: new Date().getMonth(),
    };
  }

  try {
    const saved = localStorage.getItem(FILTER_STORAGE_KEY);
    if (saved) {
      const parsed = JSON.parse(saved);
      if (typeof parsed.allTime === "boolean" && typeof parsed.year === "number" && typeof parsed.month === "number") {
        return parsed;
      }
    }
  } catch (err) {
    // ignore
  }

  return {
    allTime: false,
    year: new Date().getFullYear(),
    month: new Date().getMonth(),
  };
}

export function saveFilterState(filter: DashboardFilterState) {
  try {
    localStorage.setItem(FILTER_STORAGE_KEY, JSON.stringify(filter));
  } catch (err) {
    // ignore
  }
}

export function isSameMonthAndYear(dateStr: string | null | undefined, filter: DashboardFilterState) {
  if (!dateStr) return false;
  // Prevent timezone shifts for YYYY-MM-DD dates (like the 1st of the month shifting to the previous month in BRT)
  const isIsoDate = /^\d{4}-\d{2}-\d{2}$/.test(dateStr);
  const date = new Date(isIsoDate ? `${dateStr}T12:00:00` : dateStr);
  if (Number.isNaN(date.getTime())) return false;
  return date.getFullYear() === filter.year && date.getMonth() === filter.month;
}

const MONTHS = [
  "Janeiro", "Fevereiro", "Março", "Abril", "Maio", "Junho",
  "Julho", "Agosto", "Setembro", "Outubro", "Novembro", "Dezembro"
];

export function DashboardFilter({
  filter,
  onChange,
}: {
  filter: DashboardFilterState;
  onChange: (filter: DashboardFilterState) => void;
}) {
  const handlePrevMonth = () => {
    const nextMonth = filter.month === 0 ? 11 : filter.month - 1;
    const nextYear = filter.month === 0 ? filter.year - 1 : filter.year;
    onChange({ ...filter, allTime: false, month: nextMonth, year: nextYear });
  };

  const handleNextMonth = () => {
    const nextMonth = filter.month === 11 ? 0 : filter.month + 1;
    const nextYear = filter.month === 11 ? filter.year + 1 : filter.year;
    onChange({ ...filter, allTime: false, month: nextMonth, year: nextYear });
  };

  const toggleAllTime = () => {
    onChange({ ...filter, allTime: !filter.allTime });
  };

  return (
    <div className="flex flex-wrap items-center gap-2 mb-6">
      <div className="flex items-center rounded-lg border border-white/10 bg-white/5 p-1">
        <button
          onClick={handlePrevMonth}
          disabled={filter.allTime}
          className="p-1.5 text-muted-foreground hover:text-foreground disabled:opacity-30 disabled:hover:text-muted-foreground transition-colors"
          title="Mês anterior"
        >
          <ChevronLeft size={18} />
        </button>
        
        <div className={`flex w-32 items-center justify-center gap-2 text-sm font-medium ${filter.allTime ? "opacity-50" : ""}`}>
          <Calendar size={14} className="text-copper" />
          {MONTHS[filter.month]} {filter.year}
        </div>
        
        <button
          onClick={handleNextMonth}
          disabled={filter.allTime}
          className="p-1.5 text-muted-foreground hover:text-foreground disabled:opacity-30 disabled:hover:text-muted-foreground transition-colors"
          title="Próximo mês"
        >
          <ChevronRight size={18} />
        </button>
      </div>
      
      <button
        onClick={toggleAllTime}
        className={`rounded-lg px-4 py-2 text-sm font-medium transition-colors ${
          filter.allTime 
            ? "bg-copper text-white" 
            : "border border-white/10 bg-white/5 text-muted-foreground hover:bg-white/10"
        }`}
      >
        Todo o período
      </button>
    </div>
  );
}

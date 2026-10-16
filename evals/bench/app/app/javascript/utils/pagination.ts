export interface PageState {
  page: number;
  perPage: number;
  total: number;
}

export const DEFAULT_PER_PAGE = 25;

export function totalPages(state: PageState): number {
  return Math.max(1, Math.ceil(state.total / state.perPage));
}

export function hasNext(state: PageState): boolean {
  return state.page < totalPages(state);
}

export function hasPrevious(state: PageState): boolean {
  return state.page > 1;
}

export function pageQuery(state: Pick<PageState, "page" | "perPage">): string {
  const params = new URLSearchParams({ page: String(state.page), per_page: String(state.perPage) });
  return params.toString();
}

export function rangeLabel(state: PageState): string {
  if (state.total === 0) return "0 of 0";
  const first = (state.page - 1) * state.perPage + 1;
  const last = Math.min(state.page * state.perPage, state.total);
  return `${first}-${last} of ${state.total}`;
}

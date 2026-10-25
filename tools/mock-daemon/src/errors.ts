import type { ApiError, ErrorCode } from '@devpanel/contract';

export class HttpError extends Error {
  status: number;
  error: ApiError;
  constructor(status: number, code: ErrorCode, message: string, details?: Record<string, unknown>) {
    super(message);
    this.status = status;
    this.error = details ? { code, message, details } : { code, message };
  }
}

export const notFound = (code: ErrorCode, message: string): HttpError => new HttpError(404, code, message);
export const badRequest = (message: string, details?: Record<string, unknown>): HttpError =>
  new HttpError(400, 'BAD_REQUEST', message, details);

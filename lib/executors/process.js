/**
 * 子进程工具：带超时、输出收集，供 Blender / Unity executor 复用。
 */

import { spawn } from 'node:child_process'

/**
 * 跑一个子进程并收集输出。
 *
 * @param {string} command
 * @param {string[]} args
 * @param {{ timeoutMs?: number, cwd?: string, env?: Record<string, string>, onLine?: (line: string, stream: 'stdout' | 'stderr') => void }} [options]
 * @returns {Promise<{ code: number | null, signal: string | null, timedOut: boolean, stdout: string, stderr: string }>}
 */
export function runProcess(command, args, options = {}) {
  const timeoutMs = Number.isFinite(options.timeoutMs) && options.timeoutMs > 0 ? options.timeoutMs : 180000
  const onLine = typeof options.onLine === 'function' ? options.onLine : null

  return new Promise((resolve, reject) => {
    let child
    try {
      child = spawn(command, args, {
        cwd: options.cwd,
        env: { ...process.env, ...(options.env || {}) },
        stdio: ['ignore', 'pipe', 'pipe'],
      })
    } catch (error) {
      reject(error)
      return
    }

    let stdout = ''
    let stderr = ''
    let timedOut = false
    let lineBuffer = ''

    const flushLine = (chunk, stream) => {
      if (!onLine) return
      lineBuffer += chunk
      const lines = lineBuffer.split(/\r?\n/)
      lineBuffer = lines.pop() || ''
      for (const line of lines) {
        if (line.trim() !== '') onLine(line, stream)
      }
    }

    child.stdout?.on('data', chunk => {
      const text = chunk.toString()
      stdout += text
      flushLine(text, 'stdout')
    })
    child.stderr?.on('data', chunk => {
      const text = chunk.toString()
      stderr += text
      flushLine(text, 'stderr')
    })

    const timer = setTimeout(() => {
      timedOut = true
      try {
        child.kill('SIGTERM')
      } catch {
        /* 进程可能已经退出 */
      }
      setTimeout(() => {
        try {
          child.kill('SIGKILL')
        } catch {
          /* 同上 */
        }
      }, 3000).unref?.()
    }, timeoutMs)
    timer.unref?.()

    child.on('error', error => {
      clearTimeout(timer)
      reject(error)
    })
    child.on('close', (code, signal) => {
      clearTimeout(timer)
      if (lineBuffer.trim() !== '' && onLine) onLine(lineBuffer, 'stdout')
      resolve({ code, signal, timedOut, stdout, stderr })
    })
  })
}

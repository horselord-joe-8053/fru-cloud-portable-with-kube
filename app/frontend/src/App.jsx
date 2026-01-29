import React, { useEffect, useState } from 'react'

function StatCard({ label, value }) {
  return (
    <div
      style={{
        border: '1px solid #ddd',
        borderRadius: 12,
        padding: 10,
        minWidth: 160,
      }}
    >
      <div style={{ fontSize: 11, opacity: 0.7 }}>{label}</div>
      <div style={{ fontSize: 18, fontWeight: 600 }}>{value ?? '—'}</div>
    </div>
  )
}

function SmallTable({ title, rows, cols }) {
  return (
    <div style={{ marginTop: 20 }}>
      <div style={{ fontWeight: 700, marginBottom: 8 }}>{title}</div>
      <div style={{ overflowX: 'auto' }}>
        <table style={{ borderCollapse: 'collapse', minWidth: 420 }}>
          <thead>
            <tr>
              {cols.map(c => (
                <th key={c.key} style={{ textAlign:'left', borderBottom:'1px solid #ddd', padding:'8px 10px' }}>{c.label}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows?.map((r, i) => (
              <tr key={i}>
                {cols.map(c => (
                  <td key={c.key} style={{ borderBottom:'1px solid #f0f0f0', padding:'8px 10px' }}>{r[c.key]}</td>
                ))}
              </tr>
            ))}
            {!rows?.length && <tr><td colSpan={cols.length} style={{ padding:'10px' }}>—</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  )
}

export default function App() {
  const [stats, setStats] = useState(null)
  const [err, setErr] = useState(null)

  async function load() {
    setErr(null)
    try {
      const res = await fetch('/api/stats')
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      setStats(await res.json())
    } catch (e) {
      setErr(String(e))
    }
  }

  useEffect(() => { load() }, [])

  return (
    <div style={{ fontFamily:'system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial', padding:24 }}>
      <h1 style={{ marginTop:0 }}>Fridge Sales Stats</h1>
      <p style={{ marginTop:0, opacity:.8 }}>UI calls <code>/api/stats</code>. Ingress routes <code>/api</code> to FastAPI and <code>/</code> to UI.</p>

      <div style={{ display:'flex', gap:12, flexWrap:'wrap' }}>
        <StatCard label="Rows" value={stats?.row_count} />
        <StatCard label="Min Price" value={stats?.min_price} />
        <StatCard label="Max Price" value={stats?.max_price} />
        <StatCard label="Avg Price" value={stats?.avg_price} />
        <StatCard label="Min Rating" value={stats?.min_rating} />
        <StatCard label="Max Rating" value={stats?.max_rating} />
        <StatCard label="Avg Rating" value={stats?.avg_rating} />
      </div>

      <div style={{ marginTop:16 }}>
        <button onClick={load} style={{ padding:'10px 14px', borderRadius:10, border:'1px solid #ddd', cursor:'pointer' }}>Refresh</button>
        {err && <span style={{ marginLeft:12, color:'crimson' }}>Error: {err}</span>}
      </div>

      <SmallTable title="Sentiment breakdown" rows={stats?.sentiments} cols={[{key:'sentiment',label:'Sentiment'},{key:'count',label:'Count'}]} />
      <SmallTable title="Top 5 brands" rows={stats?.top_brands} cols={[{key:'brand',label:'Brand'},{key:'count',label:'Count'}]} />
      <SmallTable title="Top 5 stores" rows={stats?.top_stores} cols={[{key:'store_name',label:'Store'},{key:'count',label:'Count'}]} />

      <hr style={{ margin:'24px 0' }} />
      <div style={{ fontSize:12, opacity:.75 }}>API: <code>/api/stats</code></div>
    </div>
  )
}

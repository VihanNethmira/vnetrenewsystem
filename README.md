# VNET — VPN Subscription Renewal System

Renews **existing** NetMod (.nmc) client configs on your 3x-UI (Sanaei) panel —
no new configs are ever created. Customers submit a renewal request + payment
slip; the admin approves it; the backend automates the 3x-UI panel to reset
traffic and extend expiry by 30 days.

## Project structure

```
vnet-project/
├── backend/                 # Flask API + SQLite + 3x-UI automation
│   ├── app.py
│   ├── requirements.txt
│   ├── .env.example
│   └── uploads/              # payment slips are stored here (gitignored)
└── frontend/                 # Next.js (App Router) + Tailwind CSS
    ├── app/
    │   ├── page.js            # customer renewal form
    │   ├── admin/page.js      # admin dashboard
    │   ├── layout.js
    │   └── globals.css
    ├── package.json
    ├── tailwind.config.js
    ├── postcss.config.js
    ├── next.config.js
    └── .env.local.example
```

## 1. Backend setup

```bash
cd backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

cp .env.example .env
# Edit .env:
#   XUI_BASE_URL     -> e.g. https://your-vps-ip:2053  (your 3x-ui panel URL)
#   XUI_USERNAME     -> 3x-ui admin username
#   XUI_PASSWORD     -> 3x-ui admin password
#   ADMIN_API_TOKEN  -> any long random string, shared with the admin dashboard
#   FRONTEND_ORIGIN  -> http://localhost:3000 (or your deployed frontend URL)

python app.py
# Flask runs on http://localhost:5000
```

For production, run behind gunicorn + nginx instead of the dev server, e.g.:
```bash
gunicorn -w 2 -b 127.0.0.1:5000 app:app
```

### How the 3x-UI automation works (`renew_on_xui` in app.py)
1. `POST /login` with panel admin credentials → session cookie stored on a
   `requests.Session()`.
2. `GET /panel/api/inbounds/list` → searches every inbound's client list for
   one whose `email` matches the NetMod username the customer typed in. This
   gives us the real `inbound_id` and client `uuid` **without** the admin
   having to look them up manually.
3. `POST /panel/api/inbounds/{inbound_id}/resetClientTraffic/{email}` → usage
   reset to 0.
4. `POST /panel/api/inbounds/updateClient/{uuid}` → sends the full client
   object back with `expiryTime` set to `now + 30 days` (ms epoch), and
   optionally refreshes `totalGB` based on the chosen package.

If any step fails (bad credentials, panel unreachable, client not found), the
renewal record is marked `Failed` with the error message saved in
`admin_note`, and nothing partially-applies silently — you can see exactly
what went wrong and retry after fixing it.

## 2. Frontend setup

```bash
cd frontend
npm install

cp .env.local.example .env.local
# Edit .env.local:
#   NEXT_PUBLIC_API_URL   -> http://localhost:5000 (or your deployed backend URL)
#   NEXT_PUBLIC_ADMIN_TOKEN is NOT required to be set here — the admin enters
#   the token directly on the /admin login screen and it's saved in that
#   browser's localStorage.

npm run dev
# Next.js runs on http://localhost:3000
```

- Customer form: `http://localhost:3000/`
- Admin dashboard: `http://localhost:3000/admin` (prompts for the admin token
  on first visit — this must match `ADMIN_API_TOKEN` in the backend `.env`)

## 3. Security notes for production

- The admin dashboard currently uses a single static bearer token for
  simplicity. Before going live, replace this with real authentication
  (e.g. Flask-Login + hashed password, or a proper JWT flow).
- Put the Flask backend behind HTTPS (nginx + certbot) — the admin token and
  session cookie should never travel over plain HTTP.
- `XUI_VERIFY_SSL=False` is convenient for self-signed panel certificates but
  disables certificate checking. Use a real certificate on the panel and set
  this to `True` when possible.
- Payment slip files are served only to authenticated admin requests
  (`/api/uploads/<filename>` checks the bearer token), not publicly exposed.
- Consider adding rate limiting to `/api/renewals` (e.g. Flask-Limiter) to
  prevent spam submissions.

## 4. Customizing packages / quotas

Edit `PACKAGE_QUOTAS_GB` in `backend/app.py` — this dict is the single source
of truth. The frontend automatically loads this list from `GET /api/packages`,
so both stay in sync.

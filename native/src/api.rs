use crate::models::{DaemonEndpoint, Prefs, Rule, Server, Status, Subscription};
use reqwest::blocking::Client;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Debug)]
pub enum ApiError {
    NotRunning,
    Io(std::io::Error),
    Json(serde_json::Error),
    Http(reqwest::Error),
    DaemonError(String),
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ApiError::NotRunning => write!(f, "Mosaic daemon is not running"),
            ApiError::Io(e) => write!(f, "IO error: {}", e),
            ApiError::Json(e) => write!(f, "JSON error: {}", e),
            ApiError::Http(e) => write!(f, "HTTP error: {}", e),
            ApiError::DaemonError(e) => write!(f, "Daemon error: {}", e),
        }
    }
}

impl std::error::Error for ApiError {}

pub fn get_data_dir() -> PathBuf {
    if let Ok(dir) = env::var("MOSAIC_DATA_DIR") {
        return PathBuf::from(dir);
    }

    if cfg!(target_os = "windows") {
        if let Ok(progdata) = env::var("ProgramData") {
            Path::new(&progdata).join("Mosaic")
        } else {
            Path::new("C:\\ProgramData").join("Mosaic")
        }
    } else if cfg!(target_os = "macos") {
        if let Ok(home) = env::var("HOME") {
            Path::new(&home)
                .join("Library")
                .join("Application Support")
                .join("Mosaic")
        } else {
            PathBuf::from("/var/run/mosaic")
        }
    } else {
        if let Ok(xdg) = env::var("XDG_DATA_HOME") {
            Path::new(&xdg).join("mosaic")
        } else if let Ok(home) = env::var("HOME") {
            Path::new(&home).join(".local").join("share").join("mosaic")
        } else {
            PathBuf::from("/var/run/mosaic")
        }
    }
}

pub fn get_lockfile_path() -> PathBuf {
    get_data_dir().join("daemon.lock")
}

pub fn load_endpoint() -> Result<DaemonEndpoint, ApiError> {
    let path = get_lockfile_path();
    if !path.exists() {
        return Err(ApiError::NotRunning);
    }
    let content = fs::read_to_string(path).map_err(ApiError::Io)?;
    let mut ep: DaemonEndpoint = serde_json::from_str(&content).map_err(ApiError::Json)?;
    if ep.host.is_empty() {
        ep.host = "127.0.0.1".to_string();
    }
    if ep.port == 0 || ep.token.is_empty() {
        return Err(ApiError::NotRunning);
    }
    Ok(ep)
}

pub struct ApiClient {
    client: Client,
    base_url: String,
    token: String,
}

impl ApiClient {
    pub fn new() -> Result<Self, ApiError> {
        let ep = load_endpoint()?;
        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(ApiError::Http)?;
        Ok(Self {
            client,
            base_url: format!("http://{}:{}", ep.host, ep.port),
            token: ep.token,
        })
    }

    fn request<T, R>(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<&T>,
    ) -> Result<R, ApiError>
    where
        T: serde::Serialize + ?Sized,
        R: for<'de> serde::Deserialize<'de>,
    {
        let url = format!("{}{}", self.base_url, path);
        let mut builder = self
            .client
            .request(method, &url)
            .header("Authorization", format!("Bearer {}", self.token));

        if let Some(b) = body {
            builder = builder.json(b);
        }

        let resp = builder.send().map_err(ApiError::Http)?;
        let status = resp.status();

        if !status.is_success() {
            #[derive(serde::Deserialize)]
            struct ErrMsg {
                error: Option<String>,
            }
            if let Ok(msg) = resp.json::<ErrMsg>() {
                if let Some(e) = msg.error {
                    return Err(ApiError::DaemonError(e));
                }
            }
            return Err(ApiError::DaemonError(format!("HTTP status {}", status)));
        }

        resp.json::<R>().map_err(ApiError::Http)
    }

    fn request_no_body<R>(&self, method: reqwest::Method, path: &str) -> Result<R, ApiError>
    where
        R: for<'de> serde::Deserialize<'de>,
    {
        self.request::<(), R>(method, path, None)
    }

    pub fn ping(&self) -> Result<(), ApiError> {
        #[derive(serde::Deserialize)]
        struct PingResp {
            status: String,
        }
        let _resp: PingResp = self.request_no_body(reqwest::Method::POST, "/v1/ping")?;
        Ok(())
    }

    pub fn list_subscriptions(&self) -> Result<Vec<Subscription>, ApiError> {
        self.request_no_body(reqwest::Method::GET, "/v1/subscriptions")
    }

    pub fn add_subscription(&self, url: &str) -> Result<Subscription, ApiError> {
        #[derive(serde::Serialize)]
        struct AddReq<'a> {
            url: &'a str,
        }
        self.request(
            reqwest::Method::POST,
            "/v1/subscriptions",
            Some(&AddReq { url }),
        )
    }

    pub fn rename_subscription(&self, id: &str, name: &str) -> Result<Subscription, ApiError> {
        #[derive(serde::Serialize)]
        struct RenameReq<'a> {
            name: &'a str,
        }
        self.request(
            reqwest::Method::PATCH,
            &format!("/v1/subscriptions/{}", id),
            Some(&RenameReq { name }),
        )
    }

    pub fn delete_subscription(&self, id: &str) -> Result<(), ApiError> {
        // Handle DELETE which might return empty/null or nothing
        let url = format!("{}{}/v1/subscriptions/{}", self.base_url, "", id);
        let resp = self
            .client
            .delete(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .send()
            .map_err(ApiError::Http)?;

        let status = resp.status();
        if !status.is_success() {
            #[derive(serde::Deserialize)]
            struct ErrMsg {
                error: Option<String>,
            }
            if let Ok(msg) = resp.json::<ErrMsg>() {
                if let Some(e) = msg.error {
                    return Err(ApiError::DaemonError(e));
                }
            }
            return Err(ApiError::DaemonError(format!("HTTP status {}", status)));
        }
        Ok(())
    }

    pub fn refresh_subscription(&self, id: &str) -> Result<Subscription, ApiError> {
        self.request_no_body(
            reqwest::Method::POST,
            &format!("/v1/subscriptions/{}/refresh", id),
        )
    }

    pub fn list_servers(&self) -> Result<Vec<Server>, ApiError> {
        self.request_no_body(reqwest::Method::GET, "/v1/servers")
    }

    pub fn test_server(&self, id: &str) -> Result<Server, ApiError> {
        self.request_no_body(reqwest::Method::POST, &format!("/v1/servers/{}/test", id))
    }

    pub fn test_all_servers(&self, sub_id: &str) -> Result<(), ApiError> {
        // Returns empty or simple json on test all
        let url = format!("{}{}/v1/subscriptions/{}/test", self.base_url, "", sub_id);
        let resp = self
            .client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .send()
            .map_err(ApiError::Http)?;

        if !resp.status().is_success() {
            return Err(ApiError::DaemonError(format!(
                "HTTP status {}",
                resp.status()
            )));
        }
        Ok(())
    }

    pub fn connect(&self, server_id: &str) -> Result<(), ApiError> {
        #[derive(serde::Serialize)]
        struct ConnReq<'a> {
            server_id: &'a str,
        }
        // Returns empty body or status
        let url = format!("{}{}/v1/connect", self.base_url, "");
        let resp = self
            .client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .json(&ConnReq { server_id })
            .send()
            .map_err(ApiError::Http)?;

        if !resp.status().is_success() {
            return Err(ApiError::DaemonError(format!(
                "HTTP status {}",
                resp.status()
            )));
        }
        Ok(())
    }

    pub fn disconnect(&self) -> Result<(), ApiError> {
        let url = format!("{}{}/v1/disconnect", self.base_url, "");
        let resp = self
            .client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .send()
            .map_err(ApiError::Http)?;

        if !resp.status().is_success() {
            return Err(ApiError::DaemonError(format!(
                "HTTP status {}",
                resp.status()
            )));
        }
        Ok(())
    }

    pub fn status(&self) -> Result<Status, ApiError> {
        self.request_no_body(reqwest::Method::GET, "/v1/status")
    }

    pub fn get_prefs(&self) -> Result<Prefs, ApiError> {
        self.request_no_body(reqwest::Method::GET, "/v1/prefs")
    }

    pub fn set_prefs(&self, prefs: &Prefs) -> Result<Prefs, ApiError> {
        self.request(reqwest::Method::POST, "/v1/prefs", Some(prefs))
    }

    pub fn list_rules(&self) -> Result<Vec<Rule>, ApiError> {
        self.request_no_body(reqwest::Method::GET, "/v1/rules")
    }

    pub fn add_rule(&self, rule: &Rule) -> Result<Rule, ApiError> {
        self.request(reqwest::Method::POST, "/v1/rules", Some(rule))
    }

    pub fn delete_rule(&self, id: &str) -> Result<(), ApiError> {
        let url = format!("{}{}/v1/rules/{}", self.base_url, "", id);
        let resp = self
            .client
            .delete(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .send()
            .map_err(ApiError::Http)?;

        if !resp.status().is_success() {
            return Err(ApiError::DaemonError(format!(
                "HTTP status {}",
                resp.status()
            )));
        }
        Ok(())
    }
}

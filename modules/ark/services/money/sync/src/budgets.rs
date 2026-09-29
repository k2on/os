//! `money-sync budgets [--json]` and `money-sync delete-budget <file-id>`:
//! the budget files on the Actual server, over its own HTTP API with the
//! seeded session (an admin, so it sees and may delete all of them). What the
//! laptop's `ark service money budgets` / `delete-budget` run over ssh, for
//! getting rid of a budget someone created by accident.
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::config::{read_secret, Config};
use crate::{bail, Result};

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Budget {
    pub file_id: String,
    pub group_id: Option<String>,
    pub name: String,
    pub owner: Option<String>,
    #[serde(default)]
    pub users_with_access: Vec<Access>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Access {
    pub user_id: String,
    pub user_name: Option<String>,
    pub display_name: Option<String>,
    #[serde(default)]
    pub owner: bool,
}

impl Budget {
    /// Who owns it, as a person would say it.
    pub fn owner_name(&self) -> String {
        self.users_with_access
            .iter()
            .find(|a| a.owner)
            .map(|a| a.display_name.clone().filter(|s| !s.is_empty()).or(a.user_name.clone()).unwrap_or(a.user_id.clone()))
            .unwrap_or_else(|| "?".to_string())
    }
}

struct Server {
    url: String,
    token: String,
}

impl Server {
    fn from_config(cfg: &Config) -> Result<Server> {
        let url = cfg.actual["serverURL"].as_str().ok_or("actual.serverURL missing from the config")?.to_string();
        let token_file = cfg.actual["tokenFile"].as_str().ok_or("actual.tokenFile missing from the config")?;
        Ok(Server { url, token: read_secret(std::path::Path::new(token_file))? })
    }

    fn list(&self) -> Result<Vec<Budget>> {
        #[derive(Deserialize)]
        struct Reply {
            data: Vec<Budget>,
        }
        let reply: Reply = ureq::get(&format!("{}/sync/list-user-files", self.url))
            .set("X-ACTUAL-TOKEN", &self.token)
            .call()
            .map_err(|e| format!("listing budgets: {e}"))?
            .into_json()?;
        Ok(reply.data)
    }

    fn delete(&self, file_id: &str) -> Result<()> {
        ureq::post(&format!("{}/sync/delete-user-file", self.url))
            .set("X-ACTUAL-TOKEN", &self.token)
            .send_json(json!({ "fileId": file_id }))
            .map_err(|e| format!("deleting budget {file_id}: {e}"))?;
        Ok(())
    }
}

pub fn list(json: bool) -> Result<()> {
    let budgets = Server::from_config(&Config::load()?)?.list()?;
    if json {
        println!("{}", serde_json::to_string(&budgets)?);
        return Ok(());
    }
    if budgets.is_empty() {
        println!("no budgets on the server");
        return Ok(());
    }
    println!("{:<24} {:<38} {:<16} {}", "BUDGET", "FILE ID", "OWNER", "ACCESS");
    for b in &budgets {
        let access: Vec<String> =
            b.users_with_access.iter().filter(|a| !a.owner).filter_map(|a| a.user_name.clone()).collect();
        println!("{:<24} {:<38} {:<16} {}", b.name, b.file_id, b.owner_name(), access.join(" "));
    }
    Ok(())
}

pub fn delete(file_id: &str) -> Result<()> {
    let server = Server::from_config(&Config::load()?)?;
    let Some(budget) = server.list()?.into_iter().find(|b| b.file_id == file_id) else {
        bail!("no budget with file id {file_id}; `money-sync budgets` lists them");
    };
    server.delete(file_id)?;
    println!("deleted the budget '{}' ({file_id}) from the server", budget.name);
    Ok(())
}

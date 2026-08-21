use zbus::interface;

pub const BUS_NAME: &str = "com.ekmanch.DevialetRemote";
pub const OBJECT_PATH: &str = "/com/ekmanch/DevialetRemote/Amp";
pub const INTERFACE_NAME: &str = "com.ekmanch.DevialetRemote.Amp1";

/// D-Bus-exposed state for the "primary" amp - see main.rs's module doc for
/// what "primary" means in this phase (no amp-picker UI yet).
///
/// One row per source slot, exposed as `(name, index, enabled, selected)`
/// tuples - always exactly `devialet_protocol::SOURCE_SLOTS` (30) entries,
/// matching the amp's fixed-size broadcast layout (see
/// `devialet_protocol::Status.sources`).
#[derive(Debug, Clone, Default)]
pub struct AmpState {
    pub device_name: String,
    pub amp_ip: String,
    pub online: bool,
    pub power: bool,
    pub muted: bool,
    pub volume_raw: u8,
    pub volume_db: f64,
    pub active_source_index: u8,
    pub active_source_name: String,
    pub sources: Vec<(String, u8, bool, bool)>,
}

#[interface(name = "com.ekmanch.DevialetRemote.Amp1")]
impl AmpState {
    #[zbus(property, name = "DeviceName")]
    fn device_name(&self) -> String {
        self.device_name.clone()
    }

    #[zbus(property, name = "AmpIp")]
    fn amp_ip(&self) -> String {
        self.amp_ip.clone()
    }

    /// Whether the primary amp has been heard from within
    /// `devialet_protocol::STALE_AFTER` (8s). App-side concept, not
    /// reported by the amp itself - see docs/protocol.md.
    #[zbus(property, name = "Online")]
    fn online(&self) -> bool {
        self.online
    }

    #[zbus(property, name = "Power")]
    fn power(&self) -> bool {
        self.power
    }

    #[zbus(property, name = "Muted")]
    fn muted(&self) -> bool {
        self.muted
    }

    /// Raw 0-255 status byte, exposed alongside the decoded dB value for
    /// manual/debug verification (busctl etc.) independent of the dB
    /// formula.
    #[zbus(property, name = "VolumeRaw")]
    fn volume_raw(&self) -> u8 {
        self.volume_raw
    }

    #[zbus(property, name = "VolumeDb")]
    fn volume_db(&self) -> f64 {
        self.volume_db
    }

    #[zbus(property, name = "ActiveSourceIndex")]
    fn active_source_index(&self) -> u8 {
        self.active_source_index
    }

    #[zbus(property, name = "ActiveSourceName")]
    fn active_source_name(&self) -> String {
        self.active_source_name.clone()
    }

    /// Full 30-slot source table (name, index, enabled, selected) - see
    /// struct doc.
    #[zbus(property, name = "Sources")]
    fn sources(&self) -> Vec<(String, u8, bool, bool)> {
        self.sources.clone()
    }
}

impl AmpState {
    pub fn from_status(status: &devialet_protocol::Status, amp_ip: String, online: bool) -> Self {
        Self {
            device_name: status.device_name.clone(),
            amp_ip,
            online,
            power: status.power_on,
            muted: status.muted,
            volume_raw: status.volume_raw,
            volume_db: status.volume_db(),
            active_source_index: status.source_index,
            active_source_name: status.current_source_name().unwrap_or("").to_string(),
            sources: status
                .sources
                .iter()
                .map(|s| (s.name.clone(), s.index, s.enabled, s.selected))
                .collect(),
        }
    }
}

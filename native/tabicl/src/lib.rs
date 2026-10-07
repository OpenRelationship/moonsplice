//! TabICLv2 in Candle, run inside Moonsplice: tablua ranks its candidate moves with it through
//! `host.tabicl` (.robot/docs/rows.robot, level 7). `model` is the network, `prep` the classifier's own
//! preprocessing and ensemble (tabicl.sklearn), so a call takes tablua's raw rows and returns what
//! `TabICLClassifier.predict_proba` would. Parity fixtures: ~/tablua-local/data/tabicl-parity/.

pub mod model;
pub mod parity;
pub mod prep;
pub mod pyrand;

pub use model::TabIcl;

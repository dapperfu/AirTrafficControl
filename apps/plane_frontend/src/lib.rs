//! Standalone instrument panel and radio transcript for one aircraft file.
//!
//! The window loads the aircraft TOML schema, flies the local pattern, and
//! records the calls on the airport frequencies named by that file.

pub mod config;
pub mod instruments;
pub mod phrase;
pub mod radio;
pub mod sim;

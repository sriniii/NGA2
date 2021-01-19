# -*- coding: utf-8 -*-

# Run this app with `python app.py` and
# visit http://127.0.0.1:8050/ in your web browser.

import dash
import dash_core_components as dcc
import dash_html_components as html
import plotly.express as px
import plotly.graph_objects as go
import pandas as pd
pd.options.plotting.backend = "plotly"

# Process here the input file to obtain simulation parameters
with open('input','r') as input:
    input.read()

# Define imbibed volume figure here
df = pd.read_csv('monitor/dropinfo', delim_whitespace=True, header=None, skiprows=2, usecols=[1, 4, 5], names=['Time', 'Vtot', 'Vimb'])
df['Iper'] = 100*df['Vimb']/df['Vtot']
df['Tper'] = 100*df['Vtot']/df['Vtot']

fig=go.Figure()
fig.add_trace(go.Scatter(x=df['Time'], y=df['Iper'], fill='tozeroy', mode='none', showlegend=False)) # fill down to xaxis
fig.add_trace(go.Scatter(x=df['Time'], y=df['Tper'], fill='tonexty', mode='none', showlegend=False)) # fill to trace0 y
fig.update_layout(width=800,height=600)
fig.update_layout(title_text='Imbibition over time',title_font_size=36,title_x=0.5)
fig.update_xaxes(title_text='Normalized time',title_font_size=24,tickfont_size=24)
fig.update_yaxes(title_text='Percent imbibed',title_font_size=24,tickfont_size=24,range=[0,100])


# This is where we define the dashboard layout
app = dash.Dash(__name__)
app.layout = html.Div(children=[
    # Title of doc
    dcc.Markdown('''# NGA2 Dashboard - Imbibition Project'''),
    dcc.Markdown('''*Written by O. Desjardins, last updated 01/18/2021*'''),
    # Intro
    dcc.Markdown('''
    ### Overview

    In this dashboard, we post-process the raw data generated by NGA2's imbibition
    case. This simulation is based on the Sahoo and Louge experiment of droplet imbibition
    and spreading on a perforated plate, conducted in late 2018 on the ISS.
    '''),
    
    dcc.Graph(
    id='Volume_imbibed',
    figure=fig
    )
    
])

if __name__ == '__main__':
    app.run_server(debug=True)
